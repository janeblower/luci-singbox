#!/bin/sh
# luci-singbox-ui installer for OpenWrt 25.12.x (apk).
# Detects the device arch, installs the main apk (deps from feeds), then downloads
# and sha256-verifies the matching bbolt-client helper.
#
#   wget -O- https://raw.githubusercontent.com/janeblower/luci-singbox/main/install.sh | sh
#
# Env overrides (used by tests / mirrors):
#   APK_BASE     base URL for the apk           (default: GitHub latest release)
#   BBOLT_BASE   base URL for bbolt assets       (default: bbolt-latest release)
#   BBOLT_DEST   install path for the helper     (default: /usr/libexec/singbox-ui/bbolt-client)
set -eu

# NOTE: fixed tag form (/releases/download/latest/), NOT /releases/latest/download/.
# The rolling release is a *prerelease*, and the /releases/latest/ selector ignores
# prereleases (→ 404). "latest" here is the literal tag name, like "bbolt-latest".
APK_BASE="${APK_BASE:-https://github.com/janeblower/luci-singbox/releases/download/latest/}"
BBOLT_BASE="${BBOLT_BASE:-https://github.com/janeblower/luci-singbox/releases/download/bbolt-latest/}"
BBOLT_DEST="${BBOLT_DEST:-/usr/libexec/singbox-ui/bbolt-client}"
APK_NAME="luci-singbox-ui.apk"

die() { echo "install: $1" >&2; exit 1; }
info() { echo ">> $1"; }

[ "$(id -u)" = "0" ] || die "must run as root"

# Downloader: prefer wget/uclient-fetch (present by default; curl is a package dep
# and not installed yet). On OpenWrt /usr/bin/wget is usually a symlink to
# uclient-fetch, but a minimal image may ship only the uclient-fetch binary with
# no wget alias — uclient-fetch takes the same -q -O flags, so probe it
# explicitly rather than falling through to the (not-yet-installed) curl branch.
# fetch <url> <out>
if command -v wget >/dev/null 2>&1; then
  fetch() { wget -q -O "$2" "$1"; }
elif command -v uclient-fetch >/dev/null 2>&1; then
  fetch() { uclient-fetch -q -O "$2" "$1"; }
elif command -v curl >/dev/null 2>&1; then
  fetch() { curl -sfL -o "$2" "$1"; }
else
  die "no downloader (need wget, uclient-fetch or curl)"
fi

# Arch detection: prefer apk --print-arch (distinguishes mips endianness).
detect_arch() {
  pa=$(apk --print-arch 2>/dev/null || true)
  case "$pa" in
    x86_64*)  echo x86_64 ;;
    aarch64*) echo aarch64 ;;
    mips64*)  echo "" ;;           # 64-bit mips unsupported (before mips*)
    mipsel*)  echo mipsel ;;       # before mips*
    mips*)    echo mips ;;
    armeb*)   echo "" ;;           # big-endian ARM unsupported
    arm*)     echo armv7 ;;
    "")
      # apk unavailable: fall back to uname -m
      m=$(uname -m 2>/dev/null || true)
      case "$m" in
        x86_64|amd64) echo x86_64 ;;
        aarch64|arm64) echo aarch64 ;;
        armv7*) echo armv7 ;;
        *) echo "" ;;
      esac ;;
    *) echo "" ;;                  # apk gave a definitive but unsupported arch
  esac
}

ARCH=$(detect_arch)
[ -n "$ARCH" ] || die "unsupported arch ($(apk --print-arch 2>/dev/null || uname -m)); supported: x86_64 aarch64 armv7 mipsel mips"
info "detected arch: $ARCH"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT INT TERM

# 1. main apk (deps resolved from configured feeds), sha256-verified.
# The apk is installed with --allow-untrusted (it is not signed by a key the
# device trusts), so without this its integrity would rest on TLS alone — unlike
# the bbolt helper below. Verify it against the release's sha256sums.txt (same
# mechanism, published by build.yml) BEFORE apk add. Die on mismatch/missing.
info "downloading $APK_NAME + sha256sums.txt"
fetch "${APK_BASE}${APK_NAME}" "$TMP/$APK_NAME" || die "apk download failed"
fetch "${APK_BASE}sha256sums.txt" "$TMP/apk_sha256sums.txt" || die "apk sha256sums.txt download failed"

want=$(awk -v a="$APK_NAME" '$2==a || $2=="*"a {print $1; exit}' "$TMP/apk_sha256sums.txt")
[ -n "$want" ] || die "no sha256 entry for $APK_NAME"
have=$(sha256sum "$TMP/$APK_NAME" | cut -d' ' -f1)
[ "$want" = "$have" ] || die "sha256 mismatch for $APK_NAME — refusing to install"
info "verified $APK_NAME sha256"

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
