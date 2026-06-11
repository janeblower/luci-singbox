#!/bin/sh
# luci-app-singbox-ui installer for OpenWrt 25.12.x (apk).
# Detects the device arch, installs the main apk (deps from feeds), then downloads
# and sha256-verifies the matching bbolt-client helper.
#
#   wget -O- https://raw.githubusercontent.com/janeblower/luci-app-sing-box/main/install.sh | sh
#
# Env overrides (used by tests / mirrors):
#   APK_BASE     base URL for the apk           (default: GitHub latest release)
#   BBOLT_BASE   base URL for bbolt assets       (default: bbolt-latest release)
#   BBOLT_DEST   install path for the helper     (default: /usr/libexec/singbox-ui/bbolt-client)
set -eu

APK_BASE="${APK_BASE:-https://github.com/janeblower/luci-app-sing-box/releases/latest/download/}"
BBOLT_BASE="${BBOLT_BASE:-https://github.com/janeblower/luci-app-sing-box/releases/download/bbolt-latest/}"
BBOLT_DEST="${BBOLT_DEST:-/usr/libexec/singbox-ui/bbolt-client}"
APK_NAME="luci-app-singbox-ui.apk"

die() { echo "install: $1" >&2; exit 1; }
info() { echo ">> $1"; }

[ "$(id -u)" = "0" ] || die "must run as root"

# Downloader: prefer wget/uclient-fetch (present by default; curl is a package dep
# and not installed yet). fetch <url> <out>
if command -v wget >/dev/null 2>&1; then
  fetch() { wget -q -O "$2" "$1"; }
elif command -v curl >/dev/null 2>&1; then
  fetch() { curl -sfL -o "$2" "$1"; }
else
  die "no downloader (need wget or curl)"
fi

# Arch detection: prefer apk --print-arch (distinguishes mips endianness).
detect_arch() {
  pa=$(apk --print-arch 2>/dev/null || true)
  case "$pa" in
    x86_64*)  echo x86_64 ;;
    aarch64*) echo aarch64 ;;
    mipsel*)  echo mipsel ;;       # before mips*
    armeb*)   echo "" ;;           # big-endian ARM unsupported
    mips*)    echo mips ;;
    arm*)     echo armv7 ;;
    *)
      m=$(uname -m 2>/dev/null || true)
      case "$m" in
        x86_64|amd64) echo x86_64 ;;
        aarch64|arm64) echo aarch64 ;;
        armv7*) echo armv7 ;;
        *) echo "" ;;
      esac ;;
  esac
}

ARCH=$(detect_arch)
[ -n "$ARCH" ] || die "unsupported arch ($(apk --print-arch 2>/dev/null || uname -m)); supported: x86_64 aarch64 armv7 mipsel mips"
info "detected arch: $ARCH"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT INT TERM

# 1. main apk (deps resolved from configured feeds)
info "downloading $APK_NAME"
fetch "${APK_BASE}${APK_NAME}" "$TMP/$APK_NAME" || die "apk download failed"
if [ "${SINGBOX_INSTALL_TEST:-}" != "1" ]; then apk update || die "apk update failed"; fi
info "installing $APK_NAME (deps from feeds)"
apk add --allow-untrusted "$TMP/$APK_NAME" || die "apk add failed"

# 2. bbolt-client helper for this arch, sha256-verified
asset="bbolt-client-rs-$ARCH"
info "downloading $asset + sha256sums.txt"
fetch "${BBOLT_BASE}${asset}" "$TMP/$asset" || die "bbolt download failed"
fetch "${BBOLT_BASE}sha256sums.txt" "$TMP/sha256sums.txt" || die "sha256sums.txt download failed"

want=$(awk -v a="$asset" '$2==a || $2=="*"a {print $1; exit}' "$TMP/sha256sums.txt")
[ -n "$want" ] || die "no sha256 entry for $asset"
have=$(sha256sum "$TMP/$asset" | cut -d' ' -f1)
[ "$want" = "$have" ] || die "sha256 mismatch for $asset — refusing to install"

mkdir -p "$(dirname "$BBOLT_DEST")"
cp "$TMP/$asset" "$BBOLT_DEST"
chmod 0755 "$BBOLT_DEST"
info "installed bbolt-client → $BBOLT_DEST"

cat <<EOF

Done. Next steps:
  /etc/init.d/rpcd restart
  /etc/init.d/singbox-ui enable && /etc/init.d/singbox-ui restart
  open LuCI → Services → sing-box UI (Rule-Sets tab)
EOF
