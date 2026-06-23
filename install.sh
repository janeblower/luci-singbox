#!/bin/sh
# luci-singbox-ui installer for OpenWrt 25.12.x (apk), FEED-based.
# Adds the signed GitHub Pages apk feed (repository + signing key) for the
# device's exact arch (via `apk --print-arch`) and installs the package by
# name — apk resolves the full dependency stack (singbox-ui, bbolt-client,
# curl, …) from the signed index.
#
#   wget -O- https://raw.githubusercontent.com/janeblower/luci-singbox/main/install.sh | sh
#
# Env overrides (used by tests / mirrors):
#   PAGES_URL             base URL of the apk feed (default: project GitHub Pages)
#   SINGBOX_FEED_MINOR    OpenWrt minor for the feed path (e.g. 25.12); else
#                         parsed from /etc/os-release VERSION_ID, else 25.12
#   APK_KEYS_DIR          where to drop the signing pubkey (default /etc/apk/keys)
#   APK_REPO_DIR          where to write the repo .list (default
#                         /etc/apk/repositories.d)
#   SINGBOX_INSTALL_TEST  set to 1 to skip `apk update` + `apk add` (dry-run)
set -eu

PAGES_URL="${PAGES_URL:-https://janeblower.github.io/luci-singbox}"
APK_KEYS_DIR="${APK_KEYS_DIR:-/etc/apk/keys}"
APK_REPO_DIR="${APK_REPO_DIR:-/etc/apk/repositories.d}"

die() { echo "install: $1" >&2; exit 1; }
info() { echo ">> $1"; }

[ "$(id -u)" = "0" ] || die "must run as root"
command -v apk >/dev/null 2>&1 || die "apk not found (this installer targets OpenWrt 25.12+)"

# Arch detection via apk --print-arch (exact OpenWrt arch string incl. variant).
ARCH="$(apk --print-arch)"
[ -n "$ARCH" ] || die "could not determine device architecture"

# Covered arches — MUST stay in sync with the bbolt_arches_* variables in
# scripts/build-apk.sh (the "bbolt-client arch map"). Update BOTH when arches change.
COVERED="x86_64 aarch64_cortex-a53 aarch64_cortex-a72 aarch64_cortex-a76 aarch64_generic arm_cortex-a5_vfpv4 arm_cortex-a7 arm_cortex-a7_neon-vfpv4 arm_cortex-a7_vfpv4 arm_cortex-a8_vfpv3 arm_cortex-a9 arm_cortex-a9_neon arm_cortex-a9_vfpv3-d16 arm_cortex-a15_neon-vfpv4 mipsel_24kc mipsel_24kc_24kf mipsel_74kc mipsel_mips32 mips_24kc mips_mips32"
case " $COVERED " in
  *" $ARCH "*) : ;;
  *) die "unsupported architecture: $ARCH (no prebuilt luci-singbox-ui package)" ;;
esac
info "detected arch: $ARCH"

# OpenWrt minor for the feed path (feed tree is <PAGES_URL>/<minor>/<arch>/...).
# Explicit override wins; else derive from /etc/os-release VERSION_ID
# (e.g. 25.12.3 -> 25.12); else default to 25.12.
MINOR="${SINGBOX_FEED_MINOR:-}"
if [ -z "$MINOR" ] && [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  if [ -n "${VERSION_ID:-}" ]; then MINOR="${VERSION_ID%.*}"; fi
fi
[ -n "$MINOR" ] || MINOR="25.12"
info "openwrt feed minor: $MINOR"

# Downloader: prefer wget/uclient-fetch (present by default; curl is a package
# dep and not installed yet). On OpenWrt /usr/bin/wget is usually a symlink to
# uclient-fetch, but a minimal image may ship only the uclient-fetch binary with
# no wget alias — uclient-fetch takes the same -q -O flags, so probe it
# explicitly rather than relying on a wget alias.
# fetch <url> <out>
if command -v wget >/dev/null 2>&1; then
  fetch() { wget -q -O "$2" "$1"; }
elif command -v uclient-fetch >/dev/null 2>&1; then
  fetch() { uclient-fetch -q -O "$2" "$1"; }
else
  die "no downloader (need wget or uclient-fetch)"
fi

# 1. Fetch the feed signing pubkey into apk's trusted keys dir.
mkdir -p "$APK_KEYS_DIR"
info "fetching feed signing key"
fetch "$PAGES_URL/luci-singbox.pem" "$APK_KEYS_DIR/luci-singbox.pem" \
  || die "failed to fetch signing key from $PAGES_URL/luci-singbox.pem"

# 2. Point apk at the signed feed index for this arch.
#    The URL MUST reference packages.adb directly (apk-tools 3 falls back to a
#    legacy APKINDEX.tar.gz path — 404 — when given a directory).
mkdir -p "$APK_REPO_DIR"
REPO_URL="$PAGES_URL/$MINOR/$ARCH/luci-singbox/packages.adb"
echo "$REPO_URL" > "$APK_REPO_DIR/luci-singbox.list"
info "added feed repo: $REPO_URL"

# 2b. Add the extended-core sibling feed (published by the cores/sing-box-extended
#     workflow, same signing key) so apk can report versions for the extended
#     cores. Removed again below if an official core is chosen ("feed on demand").
CORE_LIST="$APK_REPO_DIR/singbox-core.list"
CORE_REPO_URL="$PAGES_URL/$MINOR/$ARCH/sing-box/packages.adb"
echo "$CORE_REPO_URL" > "$CORE_LIST"
info "added core feed repo: $CORE_REPO_URL"

# Candidate sing-box cores: "<pkg>|<description>"; menu order = list order.
SINGBOX_CORES="sing-box|official OpenWrt build
sing-box-tiny|official OpenWrt build, reduced feature set
sing-box-extended|extended fork (shtorm-7) — our feed
sing-box-extended-upx|extended fork, UPX-compressed — our feed"
SINGBOX_CORE_DEFAULT="sing-box-extended-upx"

# pkg_version <pkg> — echo the version apk reports for <pkg>, else nothing.
# `apk list <pkg>` lines start with "<name>-<version>"; anchor on the digit
# right after the name so querying `sing-box` never matches `sing-box-tiny`.
pkg_version() {
  apk list "$1" 2>/dev/null | while read -r tok _; do
    case "$tok" in
      "$1"-[0-9]*) printf '%s\n' "${tok#"$1"-}"; break ;;
    esac
  done
}

# core_is_known <pkg> — succeed if <pkg> is one of the candidate cores.
core_is_known() {
  printf '%s\n' "$SINGBOX_CORES" | cut -d'|' -f1 | grep -qxF "$1"
}

# choose_core — echo the selected core package name on stdout. Honors the
# SINGBOX_CORE override (skips the menu); falls back to the default when there
# is no /dev/tty. Menu/prompt output goes to stderr so command substitution
# captures only the chosen name.
choose_core() {
  if [ -n "${SINGBOX_CORE:-}" ]; then
    core_is_known "$SINGBOX_CORE" || die "unknown SINGBOX_CORE: $SINGBOX_CORE"
    printf '%s\n' "$SINGBOX_CORE"
    return 0
  fi
  if [ ! -r /dev/tty ]; then
    printf '%s\n' "$SINGBOX_CORE_DEFAULT"
    return 0
  fi

  echo "Select sing-box core to install:" >&2
  # n lives inside the pipe's subshell only; it is not used after the loop.
  n=0
  printf '%s\n' "$SINGBOX_CORES" | while IFS='|' read -r name desc; do
    n=$((n + 1))
    ver="$(pkg_version "$name")"
    [ -n "$ver" ] || ver="(unavailable)"
    printf '  %d) %-22s %-16s %s\n' "$n" "$name" "$ver" "$desc" >&2
  done

  while :; do
    printf 'your choice (default: %s) : ' "$SINGBOX_CORE_DEFAULT" >&2
    read -r choice </dev/tty || { printf '%s\n' "$SINGBOX_CORE_DEFAULT"; return 0; }
    [ -n "$choice" ] || { printf '%s\n' "$SINGBOX_CORE_DEFAULT"; return 0; }
    case "$choice" in
      0|*[!0-9]*) echo "invalid choice: $choice" >&2; continue ;;
    esac
    name="$(printf '%s\n' "$SINGBOX_CORES" | sed -n "${choice}p" | cut -d'|' -f1)"
    [ -n "$name" ] || { echo "invalid choice: $choice" >&2; continue; }
    if [ -z "$(pkg_version "$name")" ]; then
      echo "$name is unavailable, pick another" >&2; continue
    fi
    printf '%s\n' "$name"
    return 0
  done
}

# 3. Choose the core and install it together with the LuCI app + ru translation
#    in a single apk add. SINGBOX_INSTALL_TEST=1 stops here (dry-run for tests).
if [ "${SINGBOX_INSTALL_TEST:-}" = "1" ]; then
  info "SINGBOX_INSTALL_TEST=1 — skipping apk update/add"
else
  info "updating package index"
  apk update || die "apk update failed"
  CORE="$(choose_core)"
  info "selected core: $CORE"
  # Feed on demand: keep the core feed only for our extended cores.
  case "$CORE" in
    sing-box-extended|sing-box-extended-upx) : ;;
    *) rm -f "$CORE_LIST" ;;
  esac
  # Swap cores ATOMICALLY. The conflicting old core must NOT be `apk del`'d in a
  # separate step first: singbox-ui hard-depends on `sing-box` (provided by the
  # core), so removing the current provider on its own either fails ("required by
  # singbox-ui") and aborts the install, or cascade-removes singbox-ui. Instead
  # fold the removal into the SAME `apk add` via apk-world conflict constraints
  # (`!name`, see apk-world(5)) so singbox-ui's dependency stays satisfied by the
  # new core throughout the single transaction.
  #
  # We only `!`-conflict OTHER cores by their literal package name, and never
  # `!sing-box`: the `sing-box` name is the virtual the extended cores *provide*,
  # so `!sing-box` would conflict the chosen core itself. A plain `sing-box`
  # being replaced by an extended core is displaced by that core's own
  # `conflicts: sing-box` metadata in the same transaction.
  REMOVE=""
  for _candidate in $(printf '%s\n' "$SINGBOX_CORES" | cut -d'|' -f1); do
    [ "$_candidate" != "$CORE" ] || continue
    [ "$_candidate" != "sing-box" ] || continue   # never !sing-box (provided virtual)
    apk info "$_candidate" >/dev/null 2>&1 || continue   # only if installed
    REMOVE="$REMOVE !$_candidate"
  done
  info "installing $CORE + luci-app-singbox-ui (+ ru translation)${REMOVE:+ (replacing:$REMOVE)}"
  # shellcheck disable=SC2086
  apk add "$CORE" $REMOVE luci-app-singbox-ui luci-i18n-singbox-ui-ru || die "apk add failed"
fi

cat <<EOF

Done. Next steps:
  /etc/init.d/rpcd restart
  /etc/init.d/singbox-ui enable && /etc/init.d/singbox-ui restart
  open LuCI → Services → sing-box UI
EOF
