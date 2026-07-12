#!/usr/bin/env bash
# Build the singbox-ui .apk package set directly via the OpenWrt SDK's host
# `apk` tool, skipping the full SDK build orchestration.
#
# Produces FOUR noarch packages (dependency chain singbox-ui <-
# luci-app-singbox-ui <- luci-i18n-singbox-ui-ru):
#   - singbox-ui_<version>.apk                  noarch backend (ucode handlers,
#     init.d, rpcd, uci-defaults, default config). Includes the pure-ucode
#     bbolt cache.db reader (usr/libexec/singbox-ui/bbolt-client + lib/bbolt.uc);
#     the former per-arch Rust bbolt-client package was folded in here.
#   - luci-app-singbox-ui_<version>.apk         noarch LuCI frontend (htdocs JS,
#     menu, acl). depends on singbox-ui + luci-base.
#   - luci-i18n-singbox-ui-ru_<version>.apk     noarch Russian translation.
#     depends on luci-app-singbox-ui.
#   - singbox-ui-plugin-awg_warp_<version>.apk  noarch AWG/WARP plugin.
#     depends on luci-app-singbox-ui.
#
# Usage: build-apk.sh [version] [output_dir]
#   version defaults to the most recent git tag (leading 'v' stripped).
#
# Environment knobs:
#   APK_MKPKG_STUB=1     replace real `apk mkpkg` with a touch stub (CI unit
#                        tests). Also skips SDK download/extract/po2lmo and
#                        the verify_root_owner check.
#
# Intended interpreter is bash (CI / tests invoke it as `bash build-apk.sh`),
# but the body is kept POSIX-compatible so the CI verify gate's
# `sh build-apk.sh` works under dash too: pipefail is enabled only when the
# shell supports it, and the script path falls back to $0 when BASH_SOURCE is
# unset.
set -eu
# shellcheck disable=SC3040  # pipefail is bash/ksh-only; guarded so dash skips it
( set -o pipefail ) 2>/dev/null && set -o pipefail || true

SCRIPT_PATH="${BASH_SOURCE:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# A literal TAB for manifest field-splitting. `IFS=$'\t'` is bash ANSI-C
# quoting and silently fails to split under dash (the whole line lands in the
# first field), so use a printf-derived tab that both shells honour.
TAB="$(printf '\t')"

# ---------------------------------------------------------------------------
# Package identity / metadata
# ---------------------------------------------------------------------------
# 1) singbox-ui — noarch backend.
# Runtime deps of the backend package. This is the SINGLE source of truth —
# the project is apk-only (docs/release.md), there is no buildroot Makefile to
# keep in sync. `nftables` is deliberately absent: it ships in the OpenWrt base
# via fw4 (guarded by tests/cross/test_pkg_deps.test.ts).
#   - sing-box       the proxy core this UI drives
#   - curl           subscription bodies are fetched via curl (subscription.uc)
#   - ucode + ucode-mod-fs  shipped .uc handlers require('fs') (helpers/generate/
#                    bbolt.uc cache.db reader)
#   - kmod-nft-socket / kmod-nft-tproxy  nftables.uc emits `socket transparent` and
#                    `tproxy ... to` expressions; without the kmods tproxy apply fails.
# NOTE: `nftables` is intentionally NOT listed — it ships in OpenWrt base / fw4.
# (libc is apk's base dep; jq was dropped — not used by any shipped on-device code.)
SINGBOX_NAME="singbox-ui"
SINGBOX_DESC="singbox-ui backend (config generator, nftables, subscriptions)"
SINGBOX_DEPENDS="libc sing-box curl ucode ucode-mod-fs kmod-nft-socket kmod-nft-tproxy"
SINGBOX_CONFFILE="/etc/config/singbox-ui"

# 3) luci-app-singbox-ui — noarch LuCI frontend. luci-base is implicit via the
# LuCI build machinery in the buildroot path; we list it explicitly here.
LUCIAPP_NAME="luci-app-singbox-ui"
LUCIAPP_DESC="LuCI support for singbox-ui"
LUCIAPP_DEPENDS="libc singbox-ui luci-base"

# 4) luci-i18n-singbox-ui-ru — noarch Russian translation. The i18n DOMAIN (and
# therefore the .po/.lmo basename) stays `luci-singbox-ui`; do NOT rename it.
I18N_NAME="luci-i18n-singbox-ui-ru"
I18N_DESC="Translation for luci-app-singbox-ui — Русский (Russian)"
I18N_DEPENDS="libc $LUCIAPP_NAME"
I18N_DOMAIN="luci-singbox-ui"

# 5) singbox-ui-plugin-awg_warp — noarch AWG/WARP plugin.
# Runtime components (amneziawg-tools, kmod-*, ip-full) are NOT listed here —
# they are self-provisioned at runtime via the plugin's rpcd methods.
AWGWARP_NAME="singbox-ui-plugin-awg_warp"
AWGWARP_DESC="AWG WARP plugin for luci-app-singbox-ui (Cloudflare WARP + AmneziaWG)"
AWGWARP_DEPENDS="libc $LUCIAPP_NAME"
# Own i18n domain (NOT luci-singbox-ui): .po/.pot basename and the .lmo the
# plugin's _() calls resolve against.
AWGWARP_I18N_DOMAIN="singbox-ui-plugin-awg_warp"

PKG_LICENSE="GPL-2.0-or-later"
PKG_URL="https://github.com/janeblower/luci-singbox"
PKG_MAINTAINER="Jyn"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    # Only semver tags (v1.2.3) are eligible. The repo also carries rolling
    # release tags ('latest', 'bbolt-latest') which are NOT versions — an
    # unfiltered `git describe` would happily return 'bbolt-latest' and feed
    # apk-mkpkg a version it rejects (audit 12.2). Restrict to v* and, when no
    # such tag exists, fall back to the same deterministic default CI uses.
    VERSION="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//')"
    if [ -z "$VERSION" ]; then
        VERSION="0.0.0-r$(git rev-list --count HEAD 2>/dev/null || echo 0)"
        echo "no v* git tag found — using deterministic fallback: $VERSION"
    else
        echo "using version from git tag: $VERSION"
    fi
fi

# apk-mkpkg enforces Alpine-style versions <X.Y.Z>[-rN]; reject anything else
# up front (mirrors the unknown-mode hard-fail below) so we never hand a
# garbage version like 'bbolt-latest' to apk-mkpkg.
if ! printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-r[0-9]+)?$'; then
    echo "invalid package version '$VERSION' (expected X.Y.Z or X.Y.Z-rN)" >&2
    exit 1
fi

# Per-package versions. Each of the four packages may carry its OWN version,
# passed by the CI workflow via PKG_VER_<PKG> as 0.1.0-r<N> where <N> counts only
# the commits that touched THAT package's source paths. An unchanged package then
# keeps its version+filename across pushes that don't touch it, so the feed stops
# republishing it and it stops looking like a new release every commit (the old
# behaviour, where all shared 0.0.0-r<total-commit-count>). Any unset
# override falls back to the single positional $VERSION — so local builds and
# tagged releases (one coordinated version for the whole set) work unchanged.
V_SINGBOX="${PKG_VER_SINGBOX:-$VERSION}"
V_LUCIAPP="${PKG_VER_LUCIAPP:-$VERSION}"
V_I18N="${PKG_VER_I18N:-$VERSION}"
V_AWGWARP="${PKG_VER_AWGWARP:-$VERSION}"
for _pv in "$V_SINGBOX" "$V_LUCIAPP" "$V_I18N" "$V_AWGWARP"; do
    if ! printf '%s' "$_pv" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-r[0-9]+)?$'; then
        echo "invalid per-package version '$_pv' (expected X.Y.Z or X.Y.Z-rN)" >&2
        exit 1
    fi
done

OUTPUT_DIR="${2:-$ROOT_DIR/dist}"

WORK_DIR="${WORK_DIR:-$ROOT_DIR/.build}"
mkdir -p "$WORK_DIR" "$OUTPUT_DIR"

# Clean up stale outputs from prior versions before building. Only remove THIS
# package set's outputs (4 noarch filenames), not unrelated .apks.
rm -f "$OUTPUT_DIR/${SINGBOX_NAME}_"*.apk \
      "$OUTPUT_DIR/${LUCIAPP_NAME}_"*.apk \
      "$OUTPUT_DIR/${I18N_NAME}_"*.apk \
      "$OUTPUT_DIR/${AWGWARP_NAME}_"*.apk

APK_MKPKG_STUB="${APK_MKPKG_STUB:-0}"

# ---------------------------------------------------------------------------
# SDK / po2lmo (skipped entirely under APK_MKPKG_STUB=1)
# ---------------------------------------------------------------------------
if [ "$APK_MKPKG_STUB" != "1" ]; then
    SDK_URL="${SDK_URL:-https://downloads.openwrt.org/releases/25.12.3/targets/x86/64/openwrt-sdk-25.12.3-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst}"
    SDK_CACHE_DIR="${SDK_CACHE_DIR:-$HOME/.cache/luci-singbox-ui/openwrt-sdk}"
    SDK_DIR="$WORK_DIR/sdk"

    mkdir -p "$SDK_CACHE_DIR"

    sdk_tarball="$SDK_CACHE_DIR/$(basename "$SDK_URL")"
    if [ ! -f "$sdk_tarball" ]; then
        echo ">>> Downloading SDK: $SDK_URL"
        wget -q --show-progress -O "$sdk_tarball.part" "$SDK_URL"
        mv "$sdk_tarball.part" "$sdk_tarball"
    fi

    marker="$SDK_DIR/.sdk-url"
    if [ ! -f "$marker" ] || [ "$(cat "$marker" 2>/dev/null || true)" != "$SDK_URL" ]; then
        echo ">>> Extracting SDK"
        rm -rf "$SDK_DIR"
        tmp="$(mktemp -d "$WORK_DIR/.sdk.XXXXXX")"
        tar --zstd -xf "$sdk_tarball" -C "$tmp"
        root_dir="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n1)"
        mv "$root_dir" "$SDK_DIR"
        rmdir "$tmp" 2>/dev/null || true
        echo "$SDK_URL" > "$marker"
    fi

    APK_BIN="$SDK_DIR/staging_dir/host/bin/apk"
    [ -x "$APK_BIN" ] || { echo "apk host tool missing at $APK_BIN" >&2; exit 1; }

    PO2LMO_BIN="$SDK_DIR/staging_dir/hostpkg/bin/po2lmo"
    if [ ! -x "$PO2LMO_BIN" ]; then
        echo ">>> Preparing po2lmo (from luci feed)"
        if [ ! -d "$SDK_DIR/feeds/luci" ]; then
            (cd "$SDK_DIR" && ./scripts/feeds update luci >/dev/null)
        fi
        luci_src="$SDK_DIR/feeds/luci/modules/luci-base/src"
        make -C "$luci_src" po2lmo >/dev/null
        mkdir -p "$(dirname "$PO2LMO_BIN")"
        install -m0755 "$luci_src/po2lmo" "$PO2LMO_BIN"
    fi
else
    # Stub: no real APK_BIN needed; set a placeholder so references below don't
    # use an unbound variable.
    APK_BIN="__stub__"
    PO2LMO_BIN="__stub__"
fi

# ---------------------------------------------------------------------------
# Source trees + manifests for the two file-set noarch packages.
# (i18n is po2lmo-generated, not manifest-driven.)
# ---------------------------------------------------------------------------
SINGBOX_SRC="$ROOT_DIR/singbox-ui"
SINGBOX_MANIFEST="$SCRIPT_DIR/install-manifest-singbox-ui.txt"
[ -f "$SINGBOX_MANIFEST" ] || { echo "install-manifest-singbox-ui.txt missing at $SINGBOX_MANIFEST" >&2; exit 1; }

LUCIAPP_SRC="$ROOT_DIR/luci-app-singbox-ui"
LUCIAPP_MANIFEST="$SCRIPT_DIR/install-manifest-luci-app-singbox-ui.txt"
[ -f "$LUCIAPP_MANIFEST" ] || { echo "install-manifest-luci-app-singbox-ui.txt missing at $LUCIAPP_MANIFEST" >&2; exit 1; }

AWGWARP_SRC="$ROOT_DIR/plugins/awg_warp"

# ---------------------------------------------------------------------------
# Generic manifest installer: lay down a package root from a tab-separated
# manifest (src<TAB>dst<TAB>mode; modes bin/conf/data).  Comments and blank
# lines are skipped.
# ---------------------------------------------------------------------------
install_manifest() {
    local manifest="$1" pkg_src="$2" pkg_root="$3"
    local src dst mode
    while IFS="$TAB" read -r src dst mode; do
        case "$src" in '#'*|'') continue ;; esac
        install -d "$pkg_root/$(dirname "$dst")"
        case "$mode" in
            bin)  install -m 0755 "$pkg_src/$src" "$pkg_root/$dst" ;;
            conf) install -m 0644 "$pkg_src/$src" "$pkg_root/$dst" ;;
            data) install -m 0644 "$pkg_src/$src" "$pkg_root/$dst" ;;
            *)    echo "$manifest: unknown mode '$mode' for $src" >&2; exit 1 ;;
        esac
    done < "$manifest"
}

# ---------------------------------------------------------------------------
# .list builder: enumerate package files (excluding the apk bookkeeping dir)
# into lib/apk/packages/<name>.list.
# ---------------------------------------------------------------------------
write_pkg_list() {
    local pkg_root="$1" name="$2"
    local list_dir="$pkg_root/lib/apk/packages"
    mkdir -p "$list_dir"
    (cd "$pkg_root" && find . -type f ! -path './lib/apk/packages/*' \
        | LC_ALL=C sort | sed 's#^\./#/#') > "$list_dir/${name}.list"
}

# ===========================================================================
# 1) singbox-ui (noarch) — populate + mkpkg
# ===========================================================================
SINGBOX_ROOT="$WORK_DIR/pkg-root-singbox-ui"
SINGBOX_SCRIPTS="$WORK_DIR/scripts-singbox-ui"
SINGBOX_OUT="$OUTPUT_DIR/${SINGBOX_NAME}_${V_SINGBOX}.apk"

# write_singbox_scripts <scripts_dir>
#   post-install / pre-deinstall / post-upgrade for the backend service.
write_singbox_scripts() {
    local scripts_dir="$1"
    mkdir -p "$scripts_dir"
    # NOTE: default_postinst derives the package name from `basename "${1%.*}"`,
    # i.e. the post-install script's filename minus its extension. With apk-mkpkg
    # we name the script "post-install.sh", so it resolves to "post-install" and
    # the package's file list at /lib/apk/packages/singbox-ui.list is never
    # found — which silently skips the init.d enable+start block. We call
    # default_postinst for any side-effects (uci-defaults runner) and then enable
    # /start /etc/init.d/singbox-ui explicitly. Both ops are idempotent.
    cat > "$scripts_dir/post-install.sh" <<'EOF'
#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_postinst $0 $@
[ -n "${IPKG_INSTROOT}" ] || {
  if [ -x /etc/init.d/singbox-ui ]; then
    /etc/init.d/singbox-ui enable
    /etc/init.d/singbox-ui start
  fi
  killall -HUP rpcd 2>/dev/null
}
exit 0
EOF
    cat > "$scripts_dir/pre-deinstall.sh" <<'EOF'
#!/bin/sh
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_prerm $0 $@
[ -n "${IPKG_INSTROOT}" ] || {
  if [ -x /etc/init.d/singbox-ui ]; then
    /etc/init.d/singbox-ui stop 2>/dev/null
    /etc/init.d/singbox-ui disable 2>/dev/null
  fi
}
exit 0
EOF
    cat > "$scripts_dir/post-upgrade.sh" <<'EOF'
#!/bin/sh
export PKG_UPGRADE=1
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_postinst $0 $@
[ -n "${IPKG_INSTROOT}" ] || {
  if [ -x /etc/init.d/singbox-ui ]; then
    /etc/init.d/singbox-ui enable
    # restart picks up the new generate.uc / lib code without leaving the
    # daemon down between stop and start.
    /etc/init.d/singbox-ui restart
  fi
  killall -HUP rpcd 2>/dev/null
}
exit 0
EOF
    chmod 0755 "$scripts_dir"/*.sh
}

# populate_singbox_root
#   Lay down the backend file set + .list/.conffiles + service scripts. Does
#   NOT run apk mkpkg (ownership established by callers).
populate_singbox_root() {
    rm -rf "$SINGBOX_ROOT" "$SINGBOX_SCRIPTS"
    install_manifest "$SINGBOX_MANIFEST" "$SINGBOX_SRC" "$SINGBOX_ROOT"

    # .list/.conffiles for the conffile /etc/config/singbox-ui.
    write_pkg_list "$SINGBOX_ROOT" "$SINGBOX_NAME"
    local list_dir="$SINGBOX_ROOT/lib/apk/packages"
    local conffile_hash
    conffile_hash="$(sha256sum "$SINGBOX_ROOT$SINGBOX_CONFFILE" | awk '{print $1}')"
    printf '%s\n' "$SINGBOX_CONFFILE" > "$list_dir/${SINGBOX_NAME}.conffiles"
    printf '%s %s\n' "$SINGBOX_CONFFILE" "$conffile_hash" > "$list_dir/${SINGBOX_NAME}.conffiles_static"

    write_singbox_scripts "$SINGBOX_SCRIPTS"

    if [ "$APK_MKPKG_STUB" = "1" ]; then
        : > "$SINGBOX_OUT"
    fi
}

# mkpkg_singbox
#   apk mkpkg for the noarch backend.  Must run after populate_singbox_root and
#   after ownership is correct.
#
# The package conflicts with `firewall` (it manages its own nft ruleset), but the
# pinned SDK's apk mkpkg REJECTS the field ("invalid info field: conflicts"), so
# we attempt it and fall back. The two attempts share ONE command: the earlier
# version duplicated the whole invocation for the with/without case (and again
# inside the unshare branch), which is how they drifted apart. The buildroot path
# carries PKG_CONFLICTS:=firewall regardless.
_mkpkg_singbox() {   # $1: extra -I args, possibly empty (deliberately word-split)
    # shellcheck disable=SC2086
    "$APK_BIN" mkpkg \
        --files "$SINGBOX_ROOT" \
        --output "$SINGBOX_OUT" \
        -I "name:$SINGBOX_NAME" \
        -I "version:$V_SINGBOX" \
        -I "description:$SINGBOX_DESC" \
        -I "arch:noarch" \
        -I "license:$PKG_LICENSE" \
        -I "origin:$SINGBOX_NAME" \
        -I "maintainer:$PKG_MAINTAINER" \
        -I "url:$PKG_URL" \
        -I "depends:$SINGBOX_DEPENDS" \
        -I "provides:${SINGBOX_NAME}-any" \
        $1 \
        -s "post-install:$SINGBOX_SCRIPTS/post-install.sh" \
        -s "pre-deinstall:$SINGBOX_SCRIPTS/pre-deinstall.sh" \
        -s "post-upgrade:$SINGBOX_SCRIPTS/post-upgrade.sh"
}

mkpkg_singbox() {
    if _mkpkg_singbox '-I conflicts:firewall' 2>/dev/null; then
        return 0
    fi
    echo ">>> apk mkpkg rejected 'conflicts:firewall' — building without it" >&2
    _mkpkg_singbox ''
}

# ===========================================================================
# 2) luci-app-singbox-ui (noarch) — populate + mkpkg
# ===========================================================================
LUCIAPP_ROOT="$WORK_DIR/pkg-root-luci-app"
LUCIAPP_SCRIPTS="$WORK_DIR/scripts-luci-app"
LUCIAPP_OUT="$OUTPUT_DIR/${LUCIAPP_NAME}_${V_LUCIAPP}.apk"

# write_luciapp_scripts <scripts_dir>
#   post-install only: default_postinst + flush LuCI caches + HUP rpcd. NO
#   init.d (the frontend has no service of its own).
write_luciapp_scripts() {
    local scripts_dir="$1"
    mkdir -p "$scripts_dir"
    cat > "$scripts_dir/post-install.sh" <<'EOF'
#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_postinst $0 $@
[ -n "${IPKG_INSTROOT}" ] || {
  rm -f /tmp/luci-indexcache.*
  rm -rf /tmp/luci-modulecache/
  killall -HUP rpcd 2>/dev/null
}
exit 0
EOF
    chmod 0755 "$scripts_dir"/*.sh
}

# populate_luciapp_root
#   Lay down the frontend file set (htdocs->www mapping already in the manifest
#   dst column) + .list + post-install script. No conffiles.
populate_luciapp_root() {
    rm -rf "$LUCIAPP_ROOT" "$LUCIAPP_SCRIPTS"
    install_manifest "$LUCIAPP_MANIFEST" "$LUCIAPP_SRC" "$LUCIAPP_ROOT"
    write_pkg_list "$LUCIAPP_ROOT" "$LUCIAPP_NAME"
    write_luciapp_scripts "$LUCIAPP_SCRIPTS"

    if [ "$APK_MKPKG_STUB" = "1" ]; then
        : > "$LUCIAPP_OUT"
    fi
}

# mkpkg_luciapp
#   apk mkpkg for the noarch frontend. provides/replaces the legacy
#   luci-singbox-ui name so installs migrate cleanly.
mkpkg_luciapp() {
    "$APK_BIN" mkpkg \
        --files "$LUCIAPP_ROOT" \
        --output "$LUCIAPP_OUT" \
        -I "name:$LUCIAPP_NAME" \
        -I "version:$V_LUCIAPP" \
        -I "description:$LUCIAPP_DESC" \
        -I "arch:noarch" \
        -I "license:$PKG_LICENSE" \
        -I "origin:$LUCIAPP_NAME" \
        -I "maintainer:$PKG_MAINTAINER" \
        -I "url:$PKG_URL" \
        -I "depends:$LUCIAPP_DEPENDS" \
        -I "provides:luci-singbox-ui" \
        -I "provides:${LUCIAPP_NAME}-any" \
        -I "replaces:luci-singbox-ui" \
        -s "post-install:$LUCIAPP_SCRIPTS/post-install.sh"
}

# ===========================================================================
# 3) luci-i18n-singbox-ui-ru (noarch) — populate + mkpkg
# ===========================================================================
I18N_ROOT="$WORK_DIR/pkg-root-i18n-ru"
I18N_SCRIPTS="$WORK_DIR/scripts-i18n-ru"
I18N_OUT="$OUTPUT_DIR/${I18N_NAME}_${V_I18N}.apk"

# The i18n .po now lives under the LuCI frontend package source tree. The DOMAIN
# (and the .po/.lmo basename) stays luci-singbox-ui — do NOT rename it.
PO_FILE="$LUCIAPP_SRC/po/ru/${I18N_DOMAIN}.po"
if [ ! -f "$PO_FILE" ]; then
    echo "Russian .po missing: $PO_FILE" >&2
    exit 1
fi

# populate_i18n_root
#   po2lmo the Russian .po into the LuCI i18n dir + language uci-default + .list
#   + post-install script.
populate_i18n_root() {
    rm -rf "$I18N_ROOT" "$I18N_SCRIPTS"
    install -d \
        "$I18N_ROOT/usr/lib/lua/luci/i18n" \
        "$I18N_ROOT/etc/uci-defaults"

    if [ "$APK_MKPKG_STUB" = "1" ]; then
        # Under stub: SDK not available, so skip po2lmo. Touch a placeholder .lmo
        # so the root assembly doesn't fail. The test only checks file counts and
        # apk naming, not i18n internals.
        touch "$I18N_ROOT/usr/lib/lua/luci/i18n/${I18N_DOMAIN}.ru.lmo"
    else
        "$PO2LMO_BIN" "$PO_FILE" "$I18N_ROOT/usr/lib/lua/luci/i18n/${I18N_DOMAIN}.ru.lmo"
    fi

    cat > "$I18N_ROOT/etc/uci-defaults/${I18N_NAME}" <<'EOF'
#!/bin/sh
uci -q batch <<UCI
set luci.languages.ru='Русский (Russian)'
commit luci
UCI
exit 0
EOF
    chmod 0755 "$I18N_ROOT/etc/uci-defaults/${I18N_NAME}"

    write_pkg_list "$I18N_ROOT" "$I18N_NAME"

    mkdir -p "$I18N_SCRIPTS"
    cat > "$I18N_SCRIPTS/post-install.sh" <<'EOF'
#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_postinst $0 $@
exit 0
EOF
    chmod 0755 "$I18N_SCRIPTS"/*.sh

    if [ "$APK_MKPKG_STUB" = "1" ]; then
        : > "$I18N_OUT"
    fi
}

# mkpkg_i18n
#   apk mkpkg for the noarch Russian translation.
mkpkg_i18n() {
    "$APK_BIN" mkpkg \
        --files "$I18N_ROOT" \
        --output "$I18N_OUT" \
        -I "name:$I18N_NAME" \
        -I "version:$V_I18N" \
        -I "description:$I18N_DESC" \
        -I "arch:noarch" \
        -I "license:$PKG_LICENSE" \
        -I "origin:$LUCIAPP_NAME" \
        -I "maintainer:$PKG_MAINTAINER" \
        -I "url:$PKG_URL" \
        -I "depends:$I18N_DEPENDS" \
        -I "provides:${I18N_NAME}-any" \
        -s "post-install:$I18N_SCRIPTS/post-install.sh"
}

# ===========================================================================
# 4) singbox-ui-plugin-awg_warp (noarch) — populate + mkpkg
# ===========================================================================
AWGWARP_ROOT="$WORK_DIR/pkg-root-awg-warp"
AWGWARP_SCRIPTS="$WORK_DIR/scripts-awg-warp"
AWGWARP_OUT="$OUTPUT_DIR/${AWGWARP_NAME}_${V_AWGWARP}.apk"

# write_awgwarp_scripts <scripts_dir>
#   post-install only: default_postinst + flush LuCI caches + HUP rpcd.
#   No init.d (the plugin has no service of its own).
write_awgwarp_scripts() {
    local scripts_dir="$1"
    mkdir -p "$scripts_dir"
    cat > "$scripts_dir/post-install.sh" <<'EOF'
#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_postinst $0 $@
[ -n "${IPKG_INSTROOT}" ] || {
  rm -f /tmp/luci-indexcache.*
  rm -rf /tmp/luci-modulecache/
  killall -HUP rpcd 2>/dev/null
}
exit 0
EOF
    chmod 0755 "$scripts_dir"/*.sh
}

# populate_awgwarp_root
#   Lay down the plugin file set (lib/ subtree + root/ subtree + htdocs->www mapping) + .list
#   + post-install script.
#   lib/ maps to usr/share/singbox-ui/lib/plugins/awg_warp/ (includes protocols/ subdir).
#   root/ files (usr/share/rpcd/acl.d/) are copied directly.
#   htdocs/ is remapped to www/ mirroring the luci-app-singbox-ui convention.
populate_awgwarp_root() {
    rm -rf "$AWGWARP_ROOT" "$AWGWARP_SCRIPTS"
    mkdir -p "$AWGWARP_ROOT"
    # Map lib/ -> usr/share/singbox-ui/lib/plugins/awg_warp/ (recursive, includes protocols/).
    if [ -d "$AWGWARP_SRC/lib" ]; then
        mkdir -p "$AWGWARP_ROOT/usr/share/singbox-ui/lib/plugins/awg_warp"
        cp -a "$AWGWARP_SRC/lib/." "$AWGWARP_ROOT/usr/share/singbox-ui/lib/plugins/awg_warp/"
    fi
    # Copy the root/ subtree (acl.d and any other runtime files).
    if [ -d "$AWGWARP_SRC/root" ]; then
        cp -a "$AWGWARP_SRC/root/." "$AWGWARP_ROOT/"
    fi
    # Map htdocs/luci-static/... -> www/luci-static/... (LuCI serving convention).
    if [ -d "$AWGWARP_SRC/htdocs" ]; then
        mkdir -p "$AWGWARP_ROOT/www"
        cp -a "$AWGWARP_SRC/htdocs/." "$AWGWARP_ROOT/www/"
    fi
    # The plugin ships its own i18n domain (singbox-ui-plugin-awg_warp), and its
    # tab.js calls _() 14 times — but nothing compiled the .po, so every string
    # rendered in English on a Russian UI. Build the .lmo into the plugin package
    # itself: one domain, one .po, no separate i18n subpackage to carry it.
    awgwarp_po="$AWGWARP_SRC/po/ru/${AWGWARP_I18N_DOMAIN}.po"
    if [ -f "$awgwarp_po" ]; then
        install -d "$AWGWARP_ROOT/usr/lib/lua/luci/i18n"
        if [ "$APK_MKPKG_STUB" = "1" ]; then
            touch "$AWGWARP_ROOT/usr/lib/lua/luci/i18n/${AWGWARP_I18N_DOMAIN}.ru.lmo"
        else
            "$PO2LMO_BIN" "$awgwarp_po" \
                "$AWGWARP_ROOT/usr/lib/lua/luci/i18n/${AWGWARP_I18N_DOMAIN}.ru.lmo"
        fi
    fi

    write_pkg_list "$AWGWARP_ROOT" "$AWGWARP_NAME"
    write_awgwarp_scripts "$AWGWARP_SCRIPTS"

    if [ "$APK_MKPKG_STUB" = "1" ]; then
        : > "$AWGWARP_OUT"
    fi
}

# mkpkg_awgwarp
#   apk mkpkg for the noarch AWG/WARP plugin.
mkpkg_awgwarp() {
    "$APK_BIN" mkpkg \
        --files "$AWGWARP_ROOT" \
        --output "$AWGWARP_OUT" \
        -I "name:$AWGWARP_NAME" \
        -I "version:$V_AWGWARP" \
        -I "description:$AWGWARP_DESC" \
        -I "arch:noarch" \
        -I "license:$PKG_LICENSE" \
        -I "origin:$AWGWARP_NAME" \
        -I "maintainer:$PKG_MAINTAINER" \
        -I "url:$PKG_URL" \
        -I "depends:$AWGWARP_DEPENDS" \
        -I "provides:${AWGWARP_NAME}-any" \
        -s "post-install:$AWGWARP_SCRIPTS/post-install.sh"
}

# ===========================================================================
# Build dispatch — three ownership modes, all four packages.
# ===========================================================================
echo ">>> Building apk packages"

if [ "$APK_MKPKG_STUB" = "1" ]; then
    # Stub path: populate every root + touch stub outputs. No SDK or ownership.
    populate_singbox_root
    populate_luciapp_root
    populate_i18n_root
    populate_awgwarp_root
elif [ "$(id -u)" -eq 0 ]; then
    # Already running as root — populate the roots, chown 0:0, then mkpkg sees
    # correct ownership.
    populate_singbox_root
    chown -R 0:0 "$SINGBOX_ROOT" "$SINGBOX_SCRIPTS"
    mkpkg_singbox

    populate_luciapp_root
    chown -R 0:0 "$LUCIAPP_ROOT" "$LUCIAPP_SCRIPTS"
    mkpkg_luciapp

    populate_i18n_root
    chown -R 0:0 "$I18N_ROOT" "$I18N_SCRIPTS"
    mkpkg_i18n

    populate_awgwarp_root
    chown -R 0:0 "$AWGWARP_ROOT" "$AWGWARP_SCRIPTS"
    mkpkg_awgwarp
elif [ "${SINGBOX_UNSHARED:-0}" != "1" ] \
        && command -v unshare >/dev/null 2>&1 && unshare -r true >/dev/null 2>&1; then
    # Unprivileged user namespace: re-exec THIS script inside it. `unshare -r` maps
    # our uid to 0, so the re-executed run takes the `id -u -eq 0` branch above and
    # reuses populate_*/mkpkg_* directly.
    #
    # The previous version ran `unshare -r sh -c '<heredoc>'` — the inner shell
    # cannot see our bash functions, so every mkpkg invocation was re-inlined by
    # hand (~145 lines), kept in sync with the real ones by eye, and needed a dozen
    # variables exported to reach it. Re-exec keeps ONE definition of each package.
    # SINGBOX_UNSHARED guards against an unshare that fails to map root, which would
    # otherwise re-exec forever.
    echo ">>> Re-executing under unshare -r (unprivileged user namespace)"
    export SINGBOX_UNSHARED=1
    exec unshare -r "$0" "$@"
else
    cat >&2 <<EOF
ERROR: cannot build a package whose files will install as root:root.
       Need either:
         - sudo: rerun as 'sudo -E bash $0 ...'
         - unprivileged user namespaces ('unshare -r' must succeed)
       Falling back to fakeroot used to silently produce packages whose
       files install as nobody:nogroup because the OpenWrt SDK's apk
       wrapper hijacks LD_PRELOAD before libfakeroot can interpose.
EOF
    exit 1
fi

# ---------------------------------------------------------------------------
# Belt-and-suspenders: verify root ownership in every produced .apk
# Skipped under APK_MKPKG_STUB=1 (stub apks are empty files, not adbdump-able)
# ---------------------------------------------------------------------------
if [ "$APK_MKPKG_STUB" != "1" ]; then
    verify_root_owner() {
        local out="$1" bad="" owners="" count=0
        local dump
        dump=$("$APK_BIN" adbdump "$out" 2>/dev/null) \
            || { echo "ERROR: adbdump failed for $out — cannot verify ownership" >&2; exit 1; }
        # All user:/group: lines this package declares.
        owners=$(printf '%s\n' "$dump" | grep -E '^[[:space:]]*(user|group):' || true)
        count=$(printf '%s\n' "$owners" | grep -c . || true)
        # Fail-closed: if adbdump's owner-field representation ever changes (keyword
        # rename, owner lines omitted for root, etc.) `bad` would be empty and the
        # gate would pass vacuously — silently disabling the safety net it exists
        # for. A package with real files MUST declare at least one owner line, so a
        # zero count means the format moved out from under us → trip the build.
        if [ "$count" -eq 0 ]; then
            echo "ERROR: $out has no user:/group: lines in adbdump — owner-field" >&2
            echo "       format may have changed; refusing to vacuously pass the" >&2
            echo "       root-ownership check (verify_root_owner)." >&2
            exit 1
        fi
        # Accept either the literal `root` or numeric uid/gid 0 (robust to apk
        # emitting `user: 0` instead of `user: root`).
        bad=$(printf '%s\n' "$owners" \
            | grep -vE '^[[:space:]]*(user|group): (root|0)$' || true)
        if [ -n "$bad" ]; then
            echo "ERROR: $out contains non-root owner/group entries:" >&2
            printf '%s\n' "$bad" | sort -u >&2
            exit 1
        fi
    }

    for out in "$OUTPUT_DIR"/*.apk; do
        verify_root_owner "$out"
    done

    echo ">>> Verifying package metadata"
    for out in "$OUTPUT_DIR"/*.apk; do
        echo "--- $(basename "$out")"
        "$APK_BIN" adbdump "$out" | grep -E "^  (name|version|arch): " || true
    done
fi

echo ">>> Built:"
for out in "$OUTPUT_DIR"/*.apk; do
    echo "    $out"
done
