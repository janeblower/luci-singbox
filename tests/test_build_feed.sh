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

# Fixtures below are built with `apk mkpkg --info KEY:VALUE` (apk-tools 3.0.5+).
# Some OpenWrt apk-tools 3 builds — including the CI qemu image — predate the
# --info long option and abort fixture creation with "unrecognized option
# 'info'", which would fail the whole suite. Probe once and SKIP gracefully when
# the running apk can't build fixtures; real coverage still runs wherever a
# capable apk exists (host SDK copy, dev boxes).
if ! "$APK" mkpkg --help 2>&1 | grep -q -- '--info'; then
  echo "SKIP test_build_feed: apk mkpkg lacks --info (apk-tools build too old)"
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
PAGES_URL="https://example.test/luci-singbox" \
RELEASE_REPO="acme/luci-singbox" \
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

# Public key published at feed root.
[ -f "$TMP/out/luci-singbox.pem" ] || fail "public key not published at feed root"

# The feed is published to the gh-pages branch and Jekyll-built by GitHub Pages
# with jekyll-theme-midnight, so build-feed emits Jekyll sources, NOT HTML.
[ -f "$TMP/out/_config.yml" ] || fail "_config.yml (Jekyll site config) missing"
grep -q "jekyll-theme-midnight" "$TMP/out/_config.yml" || fail "midnight theme not configured"
[ -f "$TMP/out/index.html" ] && fail "build-feed must not emit index.html (Jekyll renders .md)"

# Root landing (index.md) rendered with substitutions, install snippet, no junk.
[ -f "$TMP/out/index.md" ] || fail "landing index.md missing"
grep -q "example.test/luci-singbox" "$TMP/out/index.md" || fail "PAGES_URL not substituted"
grep -q "apk add luci-singbox-ui" "$TMP/out/index.md" || fail "install snippet missing"
grep -q "packages.adb" "$TMP/out/index.md" || fail "repo URL must point at packages.adb"
grep -q "github.com/acme/luci-singbox" "$TMP/out/index.md" || fail "RELEASE_REPO not substituted"
# No unsubstituted placeholders left.
grep -q "{{" "$TMP/out/index.md" && fail "unsubstituted {{...}} placeholder in landing"
# Removed for good: the legacy .ipk note and the latest-release download block.
grep -qi "ipk" "$TMP/out/index.md" && fail ".ipk mention must be gone (we have no .ipk)"
grep -q "releases/download/latest" "$TMP/out/index.md" && fail "latest-release block must be gone"

# Browsable Jekyll indexes at version + arch levels (index.md with front matter).
[ -f "$TMP/out/25.12/index.md" ] || fail "version-level index.md missing"
[ -f "$TMP/out/25.12/x86_64/index.md" ] || fail "arch-level index.md missing"
grep -q "layout: default" "$TMP/out/25.12/index.md" || fail "browse page lacks Jekyll front matter"

# Arch list derived from filenames: no stray arch dir.
[ -d "$TMP/out/25.12/mips_24kc" ] && fail "unexpected arch dir (not in fixture dist)"

echo "PASS test_build_feed"
