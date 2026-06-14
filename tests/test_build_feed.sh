#!/bin/sh
# Test for scripts/build-feed.sh against a REAL apk-tools 3 (the OpenWrt VM has
# it; a host with the SDK apk also works). A previous stub-based version of this
# test passed while the feed was actually broken on-device: apk reconstructs each
# package URL as "<name>-<version>.apk" and the feed served release-asset names
# (luci-singbox-ui-<arch>.apk) -> 404 on download. So this test now builds real
# tiny apks, runs the feed builder, and asserts that every package the generated
# index references actually exists on disk under apk's naming convention.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
fail() { echo "FAIL: $1" >&2; exit 1; }

# Locate a real apk-tools 3: VM has it on PATH; host may have the SDK copy.
APK="${SINGBOX_APK_BIN:-}"
[ -z "$APK" ] && APK="$(command -v apk 2>/dev/null || true)"
[ -z "$APK" ] && [ -x "$ROOT/.build/sdk/staging_dir/host/bin/apk" ] && APK="$ROOT/.build/sdk/staging_dir/host/bin/apk"
if [ -z "$APK" ] || ! "$APK" --version 2>/dev/null | grep -q "apk-tools 3"; then
  echo "SKIP: apk-tools 3 not available (need apk on PATH or SDK build)"
  exit 0
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Build two real apks named like the GitHub release assets (arch in the filename,
# but real name/version/arch metadata inside).
mkdir -p "$TMP/dist" "$TMP/m/x"; echo a > "$TMP/m/x/a"
( cd "$TMP/m" && "$APK" mkpkg \
    --info name:luci-singbox-ui --info version:9.9.9-r1 --info arch:x86_64 \
    --info description:t --info license:GPL-2.0-or-later \
    --files x -o "$TMP/dist/luci-singbox-ui-x86_64.apk" >/dev/null )
mkdir -p "$TMP/i/x"; echo b > "$TMP/i/x/b"
( cd "$TMP/i" && "$APK" mkpkg \
    --info name:luci-i18n-singbox-ui-ru --info version:9.9.9-r1 --info arch:all \
    --info description:t --info license:GPL-2.0-or-later \
    --files x -o "$TMP/dist/luci-i18n-singbox-ui-ru.apk" >/dev/null )
echo "DUMMY PUBLIC KEY" > "$TMP/pub.pem"

# No FEED_SIGN_KEY -> unsigned index (signing needs a key + is covered live);
# this test targets the filename/layout contract apk depends on.
FEED_PUBKEY="$TMP/pub.pem" \
LANDING_TMPL="$ROOT/feed/landing.html" \
PAGES_URL="https://example.test/luci-singbox" \
APK_BIN="$APK" \
  sh "$ROOT/scripts/build-feed.sh" 25.12 "$TMP/dist" "$TMP/out"

d="$TMP/out/25.12/x86_64/luci-singbox"

# Packages stored under apk's <name>-<version>.apk convention, NOT the asset name.
[ -f "$d/luci-singbox-ui-9.9.9-r1.apk" ] || fail "main pkg not named <name>-<version>.apk"
[ -f "$d/luci-i18n-singbox-ui-ru-9.9.9-r1.apk" ] || fail "i18n pkg not named <name>-<version>.apk"
[ -f "$d/luci-singbox-ui-x86_64.apk" ] && fail "release-asset name was not renamed"
[ -f "$d/packages.adb" ] || fail "packages.adb missing"

# REGRESSION GUARD: every package the index references must exist on disk as the
# exact <name>-<version>.apk file apk will try to download.
"$APK" adbdump "$d/packages.adb" 2>/dev/null | awk '
  /name:/    {n=$NF}
  /version:/ {v=$NF; print n"-"v".apk"}' | sort -u > "$TMP/want"
[ -s "$TMP/want" ] || fail "index has no packages"
while read -r want; do
  [ -f "$d/$want" ] || fail "index references missing file: $want"
done < "$TMP/want"

# Public key published + landing rendered with substitutions.
[ -f "$TMP/out/luci-singbox.pem" ] || fail "public key not published at feed root"
[ -f "$TMP/out/index.html" ] || fail "landing index.html missing"
grep -q "example.test/luci-singbox" "$TMP/out/index.html" || fail "PAGES_URL not substituted"
grep -q "apk add luci-singbox-ui" "$TMP/out/index.html" || fail "install snippet missing"
grep -q "packages.adb" "$TMP/out/index.html" || fail "repo URL must point at packages.adb"

# Browsable indexes at version + arch levels.
[ -f "$TMP/out/25.12/index.html" ] || fail "version-level index missing"
[ -f "$TMP/out/25.12/x86_64/index.html" ] || fail "arch-level index missing"

# Arch list derived from filenames: no stray arch dir.
[ -d "$TMP/out/25.12/mips_24kc" ] && fail "unexpected arch dir (not in fixture dist)"

echo "PASS test_build_feed"
