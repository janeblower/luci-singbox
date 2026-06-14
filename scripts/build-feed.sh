#!/bin/sh
# Build a signed, browsable apk feed tree from already-built .apk packages.
#
# Usage: build-feed.sh <version> <dist_dir> <out_dir>
#   version   OpenWrt minor used as the top path segment (e.g. 25.12)
#   dist_dir  dir containing luci-singbox-ui-<arch>.apk + luci-i18n-...-ru.apk
#   out_dir   output dir (wiped and recreated); this is what is deployed to Pages
#
# Env knobs:
#   APK_BIN        path to the apk tool (REQUIRED) — used for adbdump + mkndx.
#   FEED_SIGN_KEY  private signing key; if set, the index is signed (production).
#                  If empty, an unsigned index is produced (tests).
#   FEED_PUBKEY    public key copied to the feed root (default: feed/luci-singbox.pem)
#   LANDING_TMPL   landing template (default: feed/landing.html)
#   PAGES_URL      base URL substituted into the landing page
#   RELEASE_REPO   owner/repo for release + GitHub links (default: janeblower/luci-singbox)
#
# Why the package files are renamed: apk-tools 3 indexes carry NO per-package
# filename. The client reconstructs the download URL as "<name>-<version>.apk"
# relative to the repository's packages.adb directory (verified against the
# official OpenWrt feed: e.g. csstidy-2021.06.13~707feaec-r1.apk). The GitHub
# release assets are named luci-singbox-ui-<arch>.apk, so each package is copied
# into the feed under its apk "<name>-<version>.apk" name instead.
set -eu

VERSION="${1:?usage: build-feed.sh <version> <dist_dir> <out_dir>}"
DIST="${2:?usage: build-feed.sh <version> <dist_dir> <out_dir>}"
OUT="${3:?usage: build-feed.sh <version> <dist_dir> <out_dir>}"

REPO_NAME="luci-singbox"
I18N="luci-i18n-singbox-ui-ru.apk"
PAGES_URL="${PAGES_URL:-https://janeblower.github.io/luci-singbox}"
FEED_PUBKEY="${FEED_PUBKEY:-feed/luci-singbox.pem}"
LANDING_TMPL="${LANDING_TMPL:-feed/landing.html}"
RELEASE_REPO="${RELEASE_REPO:-janeblower/luci-singbox}"
: "${APK_BIN:?APK_BIN required (path to apk tool)}"

# Echo the "<name>-<version>.apk" filename apk reconstructs for a package file,
# read from its own metadata. Exits non-zero if either field is missing.
feed_pkg_filename() {
  "$APK_BIN" adbdump "$1" 2>/dev/null | awk '
    $1=="name:"    {n=$2}
    $1=="version:" {v=$2}
    END { if (n=="" || v=="") exit 1; printf "%s-%s.apk\n", n, v }'
}

# Copy a .apk into the feed dir under apk'"'"'s <name>-<version>.apk convention.
copy_pkg() {
  cp_src="$1"; cp_dir="$2"
  cp_name="$(feed_pkg_filename "$cp_src")" || {
    echo "cannot read package metadata from $cp_src" >&2; exit 1; }
  cp "$cp_src" "$cp_dir/$cp_name"
}

# Write a browsable index.html (themed to match the landing) listing a dir.
gen_dir_index() {
  gi_dir="$1"; gi_title="$2"
  {
    printf '<!DOCTYPE html>\n<html lang="en"><head><meta charset="utf-8">'
    printf '<meta name="viewport" content="width=device-width, initial-scale=1">'
    printf '<title>%s</title>\n' "$gi_title"
    printf '<style>body{margin:0;font-family:system-ui,-apple-system,sans-serif;'
    printf 'background:#e9ecef;color:#222;line-height:1.55}'
    printf 'header{background:#353535;color:#f5f5f5;padding:1rem 1.25rem}'
    printf 'header h1{margin:0 auto;max-width:56rem;font-size:1.2rem}'
    printf 'main{max-width:56rem;margin:1.3rem auto;padding:0 1.25rem}'
    printf 'ul{list-style:none;padding:0;margin:0}li{padding:.25rem 0}'
    printf 'a{color:#2a7ae2;text-decoration:none}a:hover{text-decoration:underline}</style>'
    printf '</head><body>\n<header><h1>%s</h1></header>\n<main>\n<ul>\n' "$gi_title"
    for gi_entry in "$gi_dir"/*; do
      [ -e "$gi_entry" ] || continue
      gi_name="$(basename "$gi_entry")"
      [ "$gi_name" = "index.html" ] && continue
      [ -d "$gi_entry" ] && gi_name="$gi_name/"
      printf '<li><a href="%s">%s</a></li>\n' "$gi_name" "$gi_name"
    done
    printf '</ul>\n</main>\n</body></html>\n'
  } > "$gi_dir/index.html"
}

# Assemble one arch directory: copy apks (renamed), build/sign the index, indexes.
build_arch_dir() {
  ba_arch="$1"
  ba_d="$OUT/$VERSION/$ba_arch/$REPO_NAME"
  mkdir -p "$ba_d"
  copy_pkg "$DIST/luci-singbox-ui-$ba_arch.apk" "$ba_d"
  if [ -f "$DIST/$I18N" ]; then
    copy_pkg "$DIST/$I18N" "$ba_d"
  fi
  if [ -n "${FEED_SIGN_KEY:-}" ]; then
    ( cd "$ba_d" && "$APK_BIN" mkndx --allow-untrusted --sign-key "$FEED_SIGN_KEY" -o packages.adb ./*.apk )
  else
    ( cd "$ba_d" && "$APK_BIN" mkndx --allow-untrusted -o packages.adb ./*.apk )
  fi
  gen_dir_index "$ba_d" "$REPO_NAME - $ba_arch - OpenWrt $VERSION"
  gen_dir_index "$OUT/$VERSION/$ba_arch" "OpenWrt $VERSION - $ba_arch"
}

rm -rf "$OUT"
mkdir -p "$OUT/$VERSION"

# Discover arches from the per-arch package filenames (never hardcode the list).
ARCHES=""
found=0
for apk in "$DIST"/luci-singbox-ui-*.apk; do
  [ -e "$apk" ] || continue
  base="$(basename "$apk")"
  arch="${base#luci-singbox-ui-}"
  arch="${arch%.apk}"
  build_arch_dir "$arch"
  ARCHES="$ARCHES $arch"
  found=1
done
[ "$found" = "1" ] || { echo "no luci-singbox-ui-*.apk in $DIST" >&2; exit 1; }

# Version-level browsable index (lists arches).
gen_dir_index "$OUT/$VERSION" "OpenWrt $VERSION - architectures"

# Publish the public signing key at the feed root.
cp "$FEED_PUBKEY" "$OUT/$REPO_NAME.pem"

# Generate the per-arch direct-download list (stable tag-based latest URLs).
DOWNLOADS=""
# shellcheck disable=SC2086
for a in $ARCHES; do
  DOWNLOADS="$DOWNLOADS<li><a href=\"https://github.com/$RELEASE_REPO/releases/download/latest/luci-singbox-ui-$a.apk\">luci-singbox-ui-$a.apk</a></li>"
done

# Render the landing page at the feed root. Scalars + the generated list. The
# list is a single line (no newlines / no '#' / '&'), so sed's '#' delimiter is
# safe.
sed -e "s#{{PAGES_URL}}#$PAGES_URL#g" \
    -e "s#{{VERSION}}#$VERSION#g" \
    -e "s#{{RELEASE_REPO}}#$RELEASE_REPO#g" \
    -e "s#{{DOWNLOADS}}#$DOWNLOADS#g" \
    "$LANDING_TMPL" > "$OUT/index.html"

echo "feed built at $OUT"
