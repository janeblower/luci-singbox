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
#   dist_dir  dir containing bbolt-client-<arch>.apk (the only per-arch package)
#             + the noarch quartet singbox-ui.apk / luci-app-singbox-ui.apk /
#             luci-i18n-singbox-ui-ru.apk / singbox-ui-plugin-awg_warp.apk
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
# release assets are named bbolt-client-<arch>.apk (per-arch) and the noarch
# quartet singbox-ui.apk / luci-app-singbox-ui.apk / luci-i18n-singbox-ui-ru.apk /
# singbox-ui-plugin-awg_warp.apk, so
# each package is copied into the feed under its apk "<name>-<version>.apk" name.
set -eu

VERSION="${1:?usage: build-feed.sh <version> <dist_dir> <out_dir>}"
DIST="${2:?usage: build-feed.sh <version> <dist_dir> <out_dir>}"
OUT="${3:?usage: build-feed.sh <version> <dist_dir> <out_dir>}"

REPO_NAME="luci-singbox"
# Noarch packages duplicated into every per-arch dir so apk at arch X can resolve
# the whole stack from one packages.adb.
CORE="singbox-ui.apk"
APP="luci-app-singbox-ui.apk"
I18N="luci-i18n-singbox-ui-ru.apk"
PLUGIN="singbox-ui-plugin-awg_warp.apk"
PAGES_URL="${PAGES_URL:-https://janeblower.github.io/luci-singbox}"
FEED_PUBKEY="${FEED_PUBKEY:-feed/luci-singbox.pem}"
RELEASE_REPO="${RELEASE_REPO:-janeblower/luci-singbox}"
: "${APK_BIN:?APK_BIN required (path to apk tool)}"

# Echo the "<name>-<version>.apk" filename apk reconstructs for a package file,
# read from its own metadata. Exits non-zero if either field is missing.
#
# adbdump is a recursive structural dump: `name:`/`version:` tokens can also
# appear nested (scripts, triggers, provides, future metadata). Anchor on the
# TOP-LEVEL 2-space indentation (`^  name: ` / `^  version: `) and take the FIRST
# match, then stop — so a nested field can never hijack the reconstructed
# filename (which apk uses to build the download URL; a wrong name -> 404). This
# mirrors the precise anchoring build-apk.sh's verify step uses on the same dump.
feed_pkg_filename() {
  "$APK_BIN" adbdump "$1" | awk '
    /^  name: /    && n=="" { n=$2 }
    /^  version: / && v=="" { v=$2 }
    n!="" && v!=""          { printf "%s-%s.apk\n", n, v; exit }
    END { if (n=="" || v=="") exit 1 }'
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
# Five packages land here: the per-arch bbolt-client plus the noarch quartet
# (core/app/i18n/plugin), the quartet duplicated into every arch dir so apk at arch X
# resolves the whole stack from this single packages.adb.
build_arch_dir() {
  ba_arch="$1"
  ba_d="$OUT/$VERSION/$ba_arch/$REPO_NAME"
  mkdir -p "$ba_d"
  copy_pkg "$DIST/bbolt-client-$ba_arch.apk" "$ba_d"
  for ba_noarch in "$CORE" "$APP" "$I18N" "$PLUGIN"; do
    if [ -f "$DIST/$ba_noarch" ]; then
      copy_pkg "$DIST/$ba_noarch" "$ba_d"
    fi
  done
  if [ -n "${FEED_SIGN_KEY:-}" ]; then
    ( cd "$ba_d" && "$APK_BIN" mkndx --allow-untrusted --sign-key "$FEED_SIGN_KEY" -o packages.adb ./*.apk )
  else
    ( cd "$ba_d" && "$APK_BIN" mkndx --allow-untrusted -o packages.adb ./*.apk )
  fi
  gen_dir_index "$ba_d" "$REPO_NAME - $ba_arch - OpenWrt $VERSION"
  gen_dir_index "$OUT/$VERSION/$ba_arch" "OpenWrt $VERSION - $ba_arch"
  # The sing-box (extended) core feed is published as a SIBLING here
  # (25.12/<arch>/sing-box/) by a separate workflow (cores/sing-box-extended);
  # it is not part of THIS build tree, so link it explicitly into the arch
  # browse index. keep_files:true on both publishers keeps the two side by side.
  printf -- '- [sing-box/](sing-box/) — sing-box (extended) core\n' >> "$OUT/$VERSION/$ba_arch/index.md"
}

rm -rf "$OUT"
mkdir -p "$OUT/$VERSION"

# Discover arches from the only per-arch package (bbolt-client); never hardcode.
found=0
for apk in "$DIST"/bbolt-client-*.apk; do
  [ -e "$apk" ] || continue
  base="$(basename "$apk")"
  arch="${base#bbolt-client-}"
  arch="${arch%.apk}"
  build_arch_dir "$arch"
  found=1
done
[ "$found" = "1" ] || { echo "no bbolt-client-*.apk in $DIST" >&2; exit 1; }

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
apk update && apk add luci-app-singbox-ui
\`\`\`

## sing-box (extended) core

An extended [sing-box](https://github.com/shtorm-7/sing-box-extended) build is
published as a sibling feed at \`${VERSION}/<arch>/sing-box/\` (a drop-in
\`sing-box\` replacement; \`-upx\` variant available). Optional — install it to
use the extended core:

\`\`\`sh
ARCH=\$(apk --print-arch)
echo "${PAGES_URL}/${VERSION}/\$ARCH/sing-box/packages.adb" > /etc/apk/repositories.d/sing-box-extended.list
apk update && apk add sing-box-extended      # or sing-box-extended-upx
\`\`\`

## Browse

- [OpenWrt ${VERSION}](${VERSION}/) — packages by architecture (incl. \`sing-box/\`)

Public signing key: [luci-singbox.pem](luci-singbox.pem)

---

Source: [${RELEASE_REPO}](https://github.com/${RELEASE_REPO})
EOF

echo "feed built at $OUT"
