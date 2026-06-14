#!/bin/sh
# Host test for scripts/build-feed.sh. Uses FEED_STUB=1 so no real apk tool /
# signing key is needed — it validates the feed TREE structure, the published
# public key, the rendered landing page, and per-directory browsable indexes.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

# --- fixture dist/ with two per-arch apks + the noarch i18n apk ---
mkdir -p "$TMP/dist"
: > "$TMP/dist/luci-singbox-ui-x86_64.apk"
: > "$TMP/dist/luci-singbox-ui-aarch64_generic.apk"
: > "$TMP/dist/luci-i18n-singbox-ui-ru.apk"
echo "DUMMY PUBLIC KEY" > "$TMP/pub.pem"

FEED_STUB=1 \
FEED_PUBKEY="$TMP/pub.pem" \
LANDING_TMPL="$ROOT/feed/landing.html" \
PAGES_URL="https://example.test/luci-singbox" \
  sh "$ROOT/scripts/build-feed.sh" 25.12 "$TMP/dist" "$TMP/out"

# --- per-arch tree, including the copied noarch i18n + stub index + dir index ---
for a in x86_64 aarch64_generic; do
  d="$TMP/out/25.12/$a/luci-singbox"
  for f in "luci-singbox-ui-$a.apk" "luci-i18n-singbox-ui-ru.apk" packages.adb index.html; do
    [ -f "$d/$f" ] || fail "missing $d/$f"
  done
done

# --- public key published at feed root ---
[ -f "$TMP/out/luci-singbox.pem" ] || fail "public key not published at feed root"

# --- landing rendered with substitutions ---
[ -f "$TMP/out/index.html" ] || fail "landing index.html missing"
grep -q "example.test/luci-singbox" "$TMP/out/index.html" || fail "PAGES_URL not substituted"
grep -q "apk add luci-singbox-ui" "$TMP/out/index.html" || fail "install snippet missing"
grep -q "25.12/\$ARCH/luci-singbox" "$TMP/out/index.html" || fail "VERSION not substituted in snippet"

# --- browsable indexes at version + arch levels ---
[ -f "$TMP/out/25.12/index.html" ] || fail "version-level index missing"
[ -f "$TMP/out/25.12/x86_64/index.html" ] || fail "arch-level index missing"

# --- arch list is derived from filenames: no stray arch dir ---
[ -d "$TMP/out/25.12/mips_24kc" ] && fail "unexpected arch dir (not in fixture dist)"

echo "PASS test_build_feed"
