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
# Russian translation package (noarch). Best-effort: installed only if present in
# the release. Same trust model as the main apk (sha256 + --allow-untrusted).
I18N_NAME="luci-i18n-singbox-ui-ru.apk"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT INT TERM

# verify_sha256 <file_basename>: look <file> up in sha256sums.txt and die on a
# mismatch. die when the file has no entry (we only verify what we ship).
verify_sha256() {
  vs_name="$1"
  vs_want=$(awk -v a="$vs_name" '$2==a || $2=="*"a {print $1; exit}' "$TMP/sha256sums.txt")
  [ -n "$vs_want" ] || die "no sha256 entry for $vs_name"
  vs_have=$(sha256sum "$TMP/$vs_name" | cut -d' ' -f1)
  [ "$vs_want" = "$vs_have" ] || die "sha256 mismatch for $vs_name — refusing to install"
  info "verified $vs_name sha256"
}

# Download the per-arch apk + sha256sums.txt, verify integrity before installing.
# Installed with --allow-untrusted (not signed by a device-trusted key); sha256
# check is the integrity gate — die on mismatch or missing entry. NOTE: the
# sha256sums.txt is co-located with the artifact on the same release host, so it
# only defends against transport corruption, NOT a compromised/MITM'd host that
# can serve both a malicious apk and a matching hash. For a stronger trust
# boundary use the signed apk-feed (its index is signed; see feed/luci-singbox.pem).
info "downloading $APK_NAME + sha256sums.txt"
fetch "${APK_BASE}${APK_NAME}" "$TMP/$APK_NAME" || die "apk download failed"
fetch "${APK_BASE}sha256sums.txt" "$TMP/sha256sums.txt" || die "sha256sums.txt download failed"

verify_sha256 "$APK_NAME"

# Russian i18n is optional — only fetch+verify it if the release carries it.
HAVE_I18N=0
if fetch "${APK_BASE}${I18N_NAME}" "$TMP/$I18N_NAME" 2>/dev/null; then
  verify_sha256 "$I18N_NAME"
  HAVE_I18N=1
else
  info "no $I18N_NAME in release — skipping Russian translation"
fi

if [ "${SINGBOX_INSTALL_TEST:-}" != "1" ]; then apk update || die "apk update failed"; fi
info "installing $APK_NAME (deps from feeds)"
apk add --allow-untrusted "$TMP/$APK_NAME" || die "apk add failed"
if [ "$HAVE_I18N" = "1" ]; then
  info "installing $I18N_NAME"
  apk add --allow-untrusted "$TMP/$I18N_NAME" || die "apk add (i18n) failed"
fi

cat <<EOF

Done. Next steps:
  /etc/init.d/rpcd restart
  /etc/init.d/singbox-ui enable && /etc/init.d/singbox-ui restart
  open LuCI → Services → sing-box UI
EOF
