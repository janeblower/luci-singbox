#!/bin/sh
# Build a signed, browsable apk feed tree from already-built .apk packages.
#
# The output tree is published to a dedicated `gh-pages` branch (see
# .github/workflows/pages.yml) and served by GitHub Pages' Jekyll build using
# the jekyll-theme-midnight theme — same model as the awg-openwrt reference.
# This script therefore emits Jekyll sources (`_config.yml` + `index.md` per
# directory), NOT pre-rendered HTML. GitHub renders the `.md` files through the
# theme at deploy time; the `.apk`/`.adb` binaries are passed through untouched.
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
#   PAGES_URL      base URL substituted into the landing page
#   RELEASE_REPO   owner/repo for the GitHub source link (default: janeblower/luci-singbox)
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

# Write a browsable Jekyll index.md (front matter + link list) for a directory.
# Jekyll + the midnight theme render this; sub-entries are listed as md links.
gen_dir_index() {
  gi_dir="$1"; gi_title="$2"
  {
    printf -- '---\nlayout: default\ntitle: %s\n---\n\n# %s\n\n' "$gi_title" "$gi_title"
    for gi_entry in "$gi_dir"/*; do
      [ -e "$gi_entry" ] || continue
      gi_name="$(basename "$gi_entry")"
      [ "$gi_name" = "index.md" ] && continue
      [ -d "$gi_entry" ] && gi_name="$gi_name/"
      printf -- '- [%s](%s)\n' "$gi_name" "$gi_name"
    done
  } > "$gi_dir/index.md"
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

# Jekyll site config — GitHub Pages renders the .md files with this theme.
cat > "$OUT/_config.yml" <<EOF
title: luci-singbox APK feed
description: APK package feed for sing-box LuCI on OpenWrt ${VERSION}.x and newer
theme: jekyll-theme-midnight
EOF

# Root landing page (Jekyll markdown). No legacy .ipk note, no latest-release
# block — the feed itself is the install path; \$ARCH / \$(apk ...) stay literal.
cat > "$OUT/index.md" <<EOF
---
layout: default
title: luci-singbox APK feed
---

# luci-singbox APK feed

Signed APK package feed for OpenWrt ${VERSION}.x and newer.

## Install via feed

On the router (OpenWrt ${VERSION}.x+, apk-based):

\`\`\`sh
ARCH=\$(apk --print-arch)
wget -O /etc/apk/keys/luci-singbox.pem ${PAGES_URL}/luci-singbox.pem
echo "${PAGES_URL}/${VERSION}/\$ARCH/luci-singbox/packages.adb" > /etc/apk/repositories.d/luci-singbox.list
apk update && apk add luci-singbox-ui
\`\`\`

## Browse

- [OpenWrt ${VERSION}](${VERSION}/) — packages by architecture

Public signing key: [luci-singbox.pem](luci-singbox.pem)

---

Source: [${RELEASE_REPO}](https://github.com/${RELEASE_REPO})
EOF

echo "feed built at $OUT"
