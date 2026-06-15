#!/usr/bin/env bash
# Build the luci-singbox-ui .apk packages directly via the OpenWrt SDK's
# host `apk` tool, skipping the full SDK build orchestration.
#
# Produces:
#   - luci-singbox-ui_<version>_<exact-arch>.apk  one per covered OpenWrt arch
#     (20 arches total), each embedding the correct bbolt-client binary
#   - luci-i18n-singbox-ui-ru_<version>.apk        noarch Russian translation
#
# Usage: build-apk.sh [version] [output_dir]
#   version defaults to the most recent git tag (leading 'v' stripped).
#
# Environment knobs:
#   BBOLT_BIN_DIR        dir containing bbolt-client-rs-<abi> for the 5 ABIs.
#                        Required unless SINGBOX_SKIP_BBOLT=1.
#   SINGBOX_SKIP_BBOLT=1 allow a binary-less local build — no BBOLT_BIN_DIR
#                        required, bbolt binary NOT embedded; the per-arch loop
#                        still runs so you get 20 apks without the binary.
#   APK_MKPKG_STUB=1     replace real `apk mkpkg` with a touch stub (CI unit
#                        tests). Also skips SDK download/extract/po2lmo and
#                        the verify_root_owner check.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="luci-singbox-ui"
APP_DESC="LuCI support for singbox-ui"
# Runtime dependencies baked into the shipped .apk. This is the PRIMARY delivery
# path (releases + feed + install.sh), so it MUST carry the same runtime needs as
# the buildroot path (LUCI_DEPENDS in luci-singbox-ui/Makefile) — keep the two in
# sync (guarded by tests/test_makefile_deps.sh):
#   - curl           subscription bodies are fetched via curl (subscription.uc)
#   - ucode + ucode-mod-fs  shipped .uc handlers require('fs') (helpers/generate/...)
#   - kmod-nft-socket / kmod-nft-tproxy  nftables.uc emits `socket transparent` and
#                    `tproxy ... to` expressions; without the kmods tproxy apply fails.
# NOTE: `nftables` is intentionally NOT listed — it ships in OpenWrt base / fw4.
# (libc is apk's base dep; jq was dropped — not used by any shipped on-device code.)
APP_DEPENDS="libc luci-base sing-box curl ucode ucode-mod-fs kmod-nft-socket kmod-nft-tproxy"
APP_CONFFILE="/etc/config/singbox-ui"

I18N_NAME="luci-i18n-singbox-ui-ru"
I18N_DESC="Translation for luci-singbox-ui — Русский (Russian)"
I18N_DEPENDS="libc $APP_NAME"

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
OUTPUT_DIR="${2:-$ROOT_DIR/dist}"

WORK_DIR="${WORK_DIR:-$ROOT_DIR/.build}"
mkdir -p "$WORK_DIR" "$OUTPUT_DIR"

# ---------------------------------------------------------------------------
# bbolt-client arch map (single source of truth)
# Each bbolt_arches_<abi> variable lists the exact OpenWrt arches that use
# that generic ABI binary.
# NOTE: install.sh's COVERED allowlist duplicates these 20 arches — update it too when arches change.
# ---------------------------------------------------------------------------
bbolt_arches_x86_64="x86_64"
bbolt_arches_aarch64="aarch64_cortex-a53 aarch64_cortex-a72 aarch64_cortex-a76 aarch64_generic"
bbolt_arches_armv7="arm_cortex-a5_vfpv4 arm_cortex-a7 arm_cortex-a7_neon-vfpv4 arm_cortex-a7_vfpv4 arm_cortex-a8_vfpv3 arm_cortex-a9 arm_cortex-a9_neon arm_cortex-a9_vfpv3-d16 arm_cortex-a15_neon-vfpv4"
bbolt_arches_mipsel="mipsel_24kc mipsel_24kc_24kf mipsel_74kc mipsel_mips32"
bbolt_arches_mips="mips_24kc mips_mips32"
BBOLT_ABIS="x86_64 aarch64 armv7 mipsel mips"

# Return the space-separated list of exact OpenWrt arches for a given ABI name.
# Using a function avoids eval-based variable indirection in bash code.
get_arches_for_abi() {
    case "$1" in
        x86_64) echo "$bbolt_arches_x86_64" ;;
        aarch64) echo "$bbolt_arches_aarch64" ;;
        armv7) echo "$bbolt_arches_armv7" ;;
        mipsel) echo "$bbolt_arches_mipsel" ;;
        mips) echo "$bbolt_arches_mips" ;;
        *) echo "unknown ABI: $1" >&2; exit 1 ;;
    esac
}

BBOLT_BIN_DIR="${BBOLT_BIN_DIR:-}"
if [ -z "$BBOLT_BIN_DIR" ] && [ "${SINGBOX_SKIP_BBOLT:-0}" != "1" ]; then
    echo "BBOLT_BIN_DIR unset (dir with bbolt-client-rs-<abi>). Set it, or SINGBOX_SKIP_BBOLT=1 for a binary-less local build." >&2
    exit 1
fi

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

PKG_SRC="$ROOT_DIR/luci-singbox-ui"
MANIFEST="$SCRIPT_DIR/install-manifest.txt"
[ -f "$MANIFEST" ] || { echo "install-manifest.txt missing at $MANIFEST" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Helper: write the three post-install/deinstall/upgrade scripts into a dir
# ---------------------------------------------------------------------------
write_app_scripts() {
    local scripts_dir="$1"
    mkdir -p "$scripts_dir"
    # NOTE: default_postinst derives the package name from `basename "${1%.*}"`,
    # i.e. the post-install script's filename minus its extension. With apk-mkpkg
    # we name the script "post-install.sh", so it resolves to "post-install" and
    # the package's file list at /lib/apk/packages/luci-singbox-ui.list is
    # never found — which silently skips the init.d enable+start block. We call
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
  rm -f /tmp/luci-indexcache.*
  rm -rf /tmp/luci-modulecache/
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
  rm -f /tmp/luci-indexcache.*
  rm -rf /tmp/luci-modulecache/
  killall -HUP rpcd 2>/dev/null
}
exit 0
EOF
    chmod 0755 "$scripts_dir"/*.sh
}

# ---------------------------------------------------------------------------
# populate_app_root <exact-arch> <abi>
#   Assembles the per-arch package root (manifest install, bbolt binary copy,
#   .list/.conffiles, scripts).  Does NOT run apk mkpkg — callers do that
#   after establishing correct ownership.
#   Root is written to $WORK_DIR/pkg-root-app-<exact-arch> so binaries don't
#   bleed between arches and the test can inspect each root independently.
#   Under APK_MKPKG_STUB=1 also touches the stub output apk.
# ---------------------------------------------------------------------------
populate_app_root() {
    local exact_arch="$1"
    local abi="$2"

    local app_root="$WORK_DIR/pkg-root-app-$exact_arch"
    local app_scripts="$WORK_DIR/scripts-app-$exact_arch"
    local app_out="$OUTPUT_DIR/${APP_NAME}_${VERSION}_${exact_arch}.apk"
    rm -rf "$app_root" "$app_scripts"

    # Install file set from manifest
    while IFS=$'\t' read -r src dst mode; do
        case "$src" in '#'*|'') continue ;; esac
        install -d "$app_root/$(dirname "$dst")"
        case "$mode" in
            bin)  install -m 0755 "$PKG_SRC/$src" "$app_root/$dst" ;;
            conf) install -m 0644 "$PKG_SRC/$src" "$app_root/$dst" ;;
            data) install -m 0644 "$PKG_SRC/$src" "$app_root/$dst" ;;
            *)    echo "install-manifest.txt: unknown mode '$mode' for $src" >&2; exit 1 ;;
        esac
    done < "$MANIFEST"

    # Embed the bbolt binary (if BBOLT_BIN_DIR is set)
    if [ -n "$BBOLT_BIN_DIR" ]; then
        install -D -m0755 "$BBOLT_BIN_DIR/bbolt-client-rs-$abi" \
            "$app_root/usr/libexec/singbox-ui/bbolt-client"
    fi

    # Build .list and .conffiles AFTER binary copy so the binary is included
    local list_dir="$app_root/lib/apk/packages"
    mkdir -p "$list_dir"
    (cd "$app_root" && find . -type f ! -path './lib/apk/packages/*' \
        | LC_ALL=C sort | sed 's#^\./#/#') > "$list_dir/${APP_NAME}.list"
    local conffile_hash
    conffile_hash="$(sha256sum "$app_root$APP_CONFFILE" | awk '{print $1}')"
    printf '%s\n' "$APP_CONFFILE" > "$list_dir/${APP_NAME}.conffiles"
    printf '%s %s\n' "$APP_CONFFILE" "$conffile_hash" > "$list_dir/${APP_NAME}.conffiles_static"

    write_app_scripts "$app_scripts"

    if [ "$APK_MKPKG_STUB" = "1" ]; then
        : > "$app_out"
        return
    fi
}

# ---------------------------------------------------------------------------
# mkpkg_main <exact-arch>
#   Runs apk mkpkg for one per-arch main package.  Must be called after
#   populate_app_root and after the root directory has correct (root:root)
#   ownership.
# ---------------------------------------------------------------------------
mkpkg_main() {
    local exact_arch="$1"
    local app_root="$WORK_DIR/pkg-root-app-$exact_arch"
    local app_scripts="$WORK_DIR/scripts-app-$exact_arch"
    local app_out="$OUTPUT_DIR/${APP_NAME}_${VERSION}_${exact_arch}.apk"
    "$APK_BIN" mkpkg \
        --files "$app_root" \
        --output "$app_out" \
        -I "name:$APP_NAME" \
        -I "version:$VERSION" \
        -I "description:$APP_DESC" \
        -I "arch:$exact_arch" \
        -I "license:$PKG_LICENSE" \
        -I "origin:$APP_NAME" \
        -I "maintainer:$PKG_MAINTAINER" \
        -I "url:$PKG_URL" \
        -I "depends:$APP_DEPENDS" \
        -I "provides:${APP_NAME}-any" \
        -s "post-install:$app_scripts/post-install.sh" \
        -s "pre-deinstall:$app_scripts/pre-deinstall.sh" \
        -s "post-upgrade:$app_scripts/post-upgrade.sh"
}

# ---------------------------------------------------------------------------
# i18n-ru package root (built once, noarch)
# ---------------------------------------------------------------------------
I18N_ROOT="$WORK_DIR/pkg-root-i18n-ru"
I18N_SCRIPTS="$WORK_DIR/scripts-i18n-ru"
rm -rf "$I18N_ROOT" "$I18N_SCRIPTS"

PO_FILE="$PKG_SRC/po/ru/${APP_NAME}.po"
if [ ! -f "$PO_FILE" ]; then
    echo "Russian .po missing: $PO_FILE" >&2
    exit 1
fi

install -d \
    "$I18N_ROOT/usr/lib/lua/luci/i18n" \
    "$I18N_ROOT/etc/uci-defaults"

if [ "$APK_MKPKG_STUB" = "1" ]; then
    # Under stub: SDK not available, so skip po2lmo. Touch a placeholder .lmo
    # so the root assembly doesn't fail. The test only checks file counts and
    # main-apk binary contents, not i18n internals.
    touch "$I18N_ROOT/usr/lib/lua/luci/i18n/${APP_NAME}.ru.lmo"
else
    "$PO2LMO_BIN" "$PO_FILE" "$I18N_ROOT/usr/lib/lua/luci/i18n/${APP_NAME}.ru.lmo"
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

i18n_list_dir="$I18N_ROOT/lib/apk/packages"
mkdir -p "$i18n_list_dir"
(cd "$I18N_ROOT" && find . -type f ! -path './lib/apk/packages/*' \
    | LC_ALL=C sort | sed 's#^\./#/#') > "$i18n_list_dir/${I18N_NAME}.list"

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

I18N_OUT="$OUTPUT_DIR/${I18N_NAME}_${VERSION}.apk"
rm -f "$I18N_OUT"

# ---------------------------------------------------------------------------
# Run apk mkpkg for all per-arch main packages + one noarch i18n
# ---------------------------------------------------------------------------
echo ">>> Building apk packages"

if [ "$APK_MKPKG_STUB" = "1" ]; then
    # Stub path: populate all per-arch roots + i18n without SDK or ownership.
    for abi in $BBOLT_ABIS; do
        for exact in $(get_arches_for_abi "$abi"); do
            populate_app_root "$exact" "$abi"
        done
    done
    : > "$I18N_OUT"
elif [ "$(id -u)" -eq 0 ]; then
    # Already running as root — populate the root, then mkpkg sees correct ownership.
    for abi in $BBOLT_ABIS; do
        for exact in $(get_arches_for_abi "$abi"); do
            app_root="$WORK_DIR/pkg-root-app-$exact"
            app_scripts="$WORK_DIR/scripts-app-$exact"
            populate_app_root "$exact" "$abi"
            chown -R 0:0 "$app_root" "$app_scripts"
            mkpkg_main "$exact"
        done
    done
    chown -R 0:0 "$I18N_ROOT" "$I18N_SCRIPTS"
    "$APK_BIN" mkpkg \
        --files "$I18N_ROOT" \
        --output "$I18N_OUT" \
        -I "name:$I18N_NAME" \
        -I "version:$VERSION" \
        -I "description:$I18N_DESC" \
        -I "arch:noarch" \
        -I "license:$PKG_LICENSE" \
        -I "origin:$APP_NAME" \
        -I "maintainer:$PKG_MAINTAINER" \
        -I "url:$PKG_URL" \
        -I "depends:$I18N_DEPENDS" \
        -I "provides:${I18N_NAME}-any" \
        -s "post-install:$I18N_SCRIPTS/post-install.sh"
elif command -v unshare >/dev/null 2>&1 && unshare -r true >/dev/null 2>&1; then
    # Unprivileged user namespace: populate roots as current user (no mkpkg yet),
    # then chown+mkpkg exactly once inside the namespace where UID 0 is mapped to us.
    for abi in $BBOLT_ABIS; do
        for exact in $(get_arches_for_abi "$abi"); do
            populate_app_root "$exact" "$abi"
        done
    done
    # Export everything the inline shell needs.
    export APP_NAME APP_DESC APP_DEPENDS APP_CONFFILE \
           I18N_NAME I18N_DESC I18N_DEPENDS \
           I18N_ROOT I18N_SCRIPTS I18N_OUT \
           APK_BIN VERSION PKG_LICENSE PKG_URL PKG_MAINTAINER \
           WORK_DIR OUTPUT_DIR \
           bbolt_arches_x86_64 bbolt_arches_aarch64 bbolt_arches_armv7 \
           bbolt_arches_mipsel bbolt_arches_mips BBOLT_ABIS
    # shellcheck disable=SC2016
    unshare -r sh -c '
        for abi in $BBOLT_ABIS; do
            eval "exacts=\$bbolt_arches_$abi"
            for exact in $exacts; do
                app_root="$WORK_DIR/pkg-root-app-$exact"
                app_scripts="$WORK_DIR/scripts-app-$exact"
                app_out="$OUTPUT_DIR/${APP_NAME}_${VERSION}_${exact}.apk"
                chown -R 0:0 "$app_root" "$app_scripts"
                "$APK_BIN" mkpkg \
                    --files "$app_root" \
                    --output "$app_out" \
                    -I "name:$APP_NAME" \
                    -I "version:$VERSION" \
                    -I "description:$APP_DESC" \
                    -I "arch:$exact" \
                    -I "license:$PKG_LICENSE" \
                    -I "origin:$APP_NAME" \
                    -I "maintainer:$PKG_MAINTAINER" \
                    -I "url:$PKG_URL" \
                    -I "depends:$APP_DEPENDS" \
                    -I "provides:${APP_NAME}-any" \
                    -s "post-install:$app_scripts/post-install.sh" \
                    -s "pre-deinstall:$app_scripts/pre-deinstall.sh" \
                    -s "post-upgrade:$app_scripts/post-upgrade.sh"
            done
        done
        chown -R 0:0 "$I18N_ROOT" "$I18N_SCRIPTS"
        "$APK_BIN" mkpkg \
            --files "$I18N_ROOT" \
            --output "$I18N_OUT" \
            -I "name:$I18N_NAME" \
            -I "version:$VERSION" \
            -I "description:$I18N_DESC" \
            -I "arch:noarch" \
            -I "license:$PKG_LICENSE" \
            -I "origin:$APP_NAME" \
            -I "maintainer:$PKG_MAINTAINER" \
            -I "url:$PKG_URL" \
            -I "depends:$I18N_DEPENDS" \
            -I "provides:${I18N_NAME}-any" \
            -s "post-install:$I18N_SCRIPTS/post-install.sh"
    '
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
