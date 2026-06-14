#!/bin/sh
# Build a signed, browsable apk feed tree from already-built .apk packages.
#
# Usage: build-feed.sh <version> <dist_dir> <out_dir>
#   version   OpenWrt minor used as the top path segment (e.g. 25.12)
#   dist_dir  dir containing luci-singbox-ui-<arch>.apk + luci-i18n-...-ru.apk
#   out_dir   output dir (wiped and recreated); this is what is deployed to Pages
#
# Env knobs:
#   FEED_STUB=1     skip the real apk tool; touch an empty packages.adb (host tests)
#   APK_BIN         path to apk tool (required unless FEED_STUB=1)
#   FEED_SIGN_KEY   path to the private signing key (required unless FEED_STUB=1)
#   FEED_PUBKEY     public key copied to the feed root (default: feed/luci-singbox.pem)
#   LANDING_TMPL    landing template (default: feed/landing.html)
#   PAGES_URL       base URL substituted into the landing page
set -eu

VERSION="${1:?usage: build-feed.sh <version> <dist_dir> <out_dir>}"
DIST="${2:?usage: build-feed.sh <version> <dist_dir> <out_dir>}"
OUT="${3:?usage: build-feed.sh <version> <dist_dir> <out_dir>}"

REPO_NAME="luci-singbox"
I18N="luci-i18n-singbox-ui-ru.apk"
PAGES_URL="${PAGES_URL:-https://janeblower.github.io/luci-singbox}"
FEED_PUBKEY="${FEED_PUBKEY:-feed/luci-singbox.pem}"
LANDING_TMPL="${LANDING_TMPL:-feed/landing.html}"

if [ "${FEED_STUB:-0}" != "1" ]; then
  : "${APK_BIN:?APK_BIN required (path to apk tool) unless FEED_STUB=1}"
  : "${FEED_SIGN_KEY:?FEED_SIGN_KEY required (path to private key) unless FEED_STUB=1}"
fi

# Write a browsable index.html listing the entries of a directory.
gen_dir_index() {
  gi_dir="$1"; gi_title="$2"
  {
    printf '<!DOCTYPE html>\n<html><head><meta charset="utf-8">'
    printf '<title>%s</title></head><body>\n<h1>%s</h1>\n<ul>\n' "$gi_title" "$gi_title"
    for gi_entry in "$gi_dir"/*; do
      [ -e "$gi_entry" ] || continue
      gi_name="$(basename "$gi_entry")"
      [ "$gi_name" = "index.html" ] && continue
      [ -d "$gi_entry" ] && gi_name="$gi_name/"
      printf '<li><a href="%s">%s</a></li>\n' "$gi_name" "$gi_name"
    done
    printf '</ul>\n</body></html>\n'
  } > "$gi_dir/index.html"
}

# Assemble one arch directory: copy apks, build/sign the index, write a dir index.
build_arch_dir() {
  ba_arch="$1"
  ba_d="$OUT/$VERSION/$ba_arch/$REPO_NAME"
  mkdir -p "$ba_d"
  cp "$DIST/luci-singbox-ui-$ba_arch.apk" "$ba_d/"
  if [ -f "$DIST/$I18N" ]; then
    cp "$DIST/$I18N" "$ba_d/"
  fi
  if [ "${FEED_STUB:-0}" = "1" ]; then
    : > "$ba_d/packages.adb"
  else
    ( cd "$ba_d" && "$APK_BIN" mkndx --allow-untrusted --sign-key "$FEED_SIGN_KEY" -o packages.adb ./*.apk )
  fi
  gen_dir_index "$ba_d" "$REPO_NAME - $ba_arch - OpenWrt $VERSION"
  gen_dir_index "$OUT/$VERSION/$ba_arch" "OpenWrt $VERSION - $ba_arch"
}

rm -rf "$OUT"
mkdir -p "$OUT/$VERSION"

# Discover arches from the per-arch package filenames (never hardcode the list).
found=0
for apk in "$DIST"/luci-singbox-ui-*.apk; do
  [ -e "$apk" ] || continue
  base="$(basename "$apk")"
  arch="${base#luci-singbox-ui-}"
  arch="${arch%.apk}"
  build_arch_dir "$arch"
  found=1
done
[ "$found" = "1" ] || { echo "no luci-singbox-ui-*.apk in $DIST" >&2; exit 1; }

# Version-level browsable index (lists arches).
gen_dir_index "$OUT/$VERSION" "OpenWrt $VERSION - architectures"

# Publish the public signing key at the feed root.
cp "$FEED_PUBKEY" "$OUT/$REPO_NAME.pem"

# Render the landing page at the feed root.
sed -e "s#{{PAGES_URL}}#$PAGES_URL#g" -e "s#{{VERSION}}#$VERSION#g" "$LANDING_TMPL" > "$OUT/index.html"

echo "feed built at $OUT"
