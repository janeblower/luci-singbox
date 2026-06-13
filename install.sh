#!/bin/sh
# luci-singbox-ui installer for OpenWrt 25.12.x (apk).
# Detects the device's exact arch via `apk --print-arch`, downloads the
# matching per-arch luci-singbox-ui-<arch>.apk from the latest release,
# sha256-verifies it, and installs it.  bbolt-client is embedded in the apk.
#
#   wget -O- https://raw.githubusercontent.com/janeblower/luci-singbox/main/install.sh | sh
#
# Env overrides (used by tests / mirrors):
#   APK_BASE              base URL for the apk assets  (default: GitHub latest release)
#   SINGBOX_INSTALL_TEST  set to 1 to skip `apk update` (dry-run mode)
set -eu

# NOTE: fixed tag form (/releases/download/latest/), NOT /releases/latest/download/.
# The rolling release is a *prerelease*, and the /releases/latest/ selector ignores
# prereleases (→ 404). "latest" here is the literal tag name.
APK_BASE="${APK_BASE:-https://github.com/janeblower/luci-singbox/releases/download/latest/}"

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

# Arch detection: prefer apk --print-arch (exact OpenWrt arch string including
# variant suffix); fall back to uname -m only when apk is absent.
ARCH="$(apk --print-arch 2>/dev/null || uname -m)"
[ -n "$ARCH" ] || die "could not determine device architecture"

# Covered arches — MUST stay in sync with the bbolt_arches_* variables in
# scripts/build-apk.sh (the "bbolt-client arch map"). Update BOTH when arches change.
COVERED="x86_64 aarch64_cortex-a53 aarch64_cortex-a72 aarch64_cortex-a76 aarch64_generic arm_cortex-a5_vfpv4 arm_cortex-a7 arm_cortex-a7_neon-vfpv4 arm_cortex-a7_vfpv4 arm_cortex-a8_vfpv3 arm_cortex-a9 arm_cortex-a9_neon arm_cortex-a9_vfpv3-d16 arm_cortex-a15_neon-vfpv4 mipsel_24kc mipsel_24kc_24kf mipsel_74kc mipsel_mips32 mips_24kc mips_mips32"
case " $COVERED " in
  *" $ARCH "*) : ;;
  *) die "unsupported architecture: $ARCH (no prebuilt luci-singbox-ui package)" ;;
esac
info "detected arch: $ARCH"

APK_NAME="luci-singbox-ui-${ARCH}.apk"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT INT TERM

# Download the per-arch apk + sha256sums.txt, verify integrity before installing.
# Installed with --allow-untrusted (not signed by a device-trusted key); sha256
# check is the integrity gate — die on mismatch or missing entry.
info "downloading $APK_NAME + sha256sums.txt"
fetch "${APK_BASE}${APK_NAME}" "$TMP/$APK_NAME" || die "apk download failed"
fetch "${APK_BASE}sha256sums.txt" "$TMP/sha256sums.txt" || die "sha256sums.txt download failed"

want=$(awk -v a="$APK_NAME" '$2==a || $2=="*"a {print $1; exit}' "$TMP/sha256sums.txt")
[ -n "$want" ] || die "no sha256 entry for $APK_NAME"
have=$(sha256sum "$TMP/$APK_NAME" | cut -d' ' -f1)
[ "$want" = "$have" ] || die "sha256 mismatch for $APK_NAME — refusing to install"
info "verified $APK_NAME sha256"

if [ "${SINGBOX_INSTALL_TEST:-}" != "1" ]; then apk update || die "apk update failed"; fi
info "installing $APK_NAME (deps from feeds)"
apk add --allow-untrusted "$TMP/$APK_NAME" || die "apk add failed"

cat <<EOF

Done. Next steps:
  /etc/init.d/rpcd restart
  /etc/init.d/singbox-ui enable && /etc/init.d/singbox-ui restart
  open LuCI → Services → sing-box UI
EOF
