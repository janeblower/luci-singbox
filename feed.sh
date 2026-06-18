#!/bin/sh
# Build a signed, browsable apk feed subtree for sing-box-extended.
# Output is the CONTENT of the gh-pages 'sing-box-extended/' subtree (peaceiris
# destination_dir adds the prefix). Mirrors scripts/build-feed.sh conventions.
#
# Usage: feed.sh <version> <dist_dir> <out_dir>
# Env: APK_BIN (required), FEED_SIGN_KEY (optional; unsigned if empty),
#      PAGES_URL (default https://janeblower.github.io/luci-singbox)
set -eu
VERSION="${1:?usage: feed.sh <version> <dist_dir> <out_dir>}"
DIST="${2:?}"; OUT="${3:?}"
: "${APK_BIN:?APK_BIN required}"
# Absolutize APK_BIN: the signing loop runs `apk mkndx` inside `( cd "$d" && ... )`,
# so a relative APK_BIN (e.g. CI's sdk/.../bin/apk) would not resolve after the cd.
case "$APK_BIN" in
  /*) ;;                                                              # already absolute
  */*) APK_BIN="$(cd "$(dirname "$APK_BIN")" && pwd)/$(basename "$APK_BIN")" ;;
  *) ;;                                                               # bare name -> PATH
esac
PAGES_URL="${PAGES_URL:-https://janeblower.github.io/luci-singbox}"

# <name>-<version>.apk filename apk reconstructs from the index (top-level fields).
feed_pkg_filename() {
  "$APK_BIN" adbdump "$1" 2>/dev/null | awk '
    /^  name: /    && n=="" { n=$2 }
    /^  version: / && v=="" { v=$2 }
    n!="" && v!=""          { printf "%s-%s.apk\n", n, v; exit }
    END { if (n=="" || v=="") exit 1 }'
}
copy_pkg() {
  _n="$(feed_pkg_filename "$1")" || { echo "no metadata in $1" >&2; exit 1; }
  cp "$1" "$2/$_n"
}
gen_dir_index() { # gen_dir_index <dir> <title>
  { printf -- '---\nlayout: default\ntitle: %s\n---\n\n# %s\n\n' "$2" "$2"
    for e in "$1"/*; do
      [ -e "$e" ] || continue; b="$(basename "$e")"
      [ "$b" = index.md ] && continue
      [ -d "$e" ] && b="$b/"
      printf -- '- [%s](%s)\n' "$b" "$b"
    done; } > "$1/index.md"
}

rm -rf "$OUT"; mkdir -p "$OUT/$VERSION"
found=0
for apk in "$DIST"/sing-box-extended_"${VERSION}"_*.apk; do
  [ -e "$apk" ] || continue
  base="$(basename "$apk")"; arch="${base#sing-box-extended_${VERSION}_}"; arch="${arch%.apk}"
  d="$OUT/$VERSION/$arch"; mkdir -p "$d"
  copy_pkg "$apk" "$d"
  upx="$DIST/sing-box-extended-upx_${VERSION}_${arch}.apk"
  [ -f "$upx" ] || { echo "missing UPX apk for $arch: $upx" >&2; exit 1; }
  copy_pkg "$upx" "$d"
  if [ -n "${FEED_SIGN_KEY:-}" ]; then
    ( cd "$d" && "$APK_BIN" mkndx --allow-untrusted --sign-key "$FEED_SIGN_KEY" -o packages.adb ./*.apk )
  else
    ( cd "$d" && "$APK_BIN" mkndx --allow-untrusted -o packages.adb ./*.apk )
  fi
  gen_dir_index "$d" "sing-box-extended - $arch - $VERSION"
  found=1
done
[ "$found" = 1 ] || { echo "no sing-box-extended_${VERSION}_*.apk in $DIST" >&2; exit 1; }

gen_dir_index "$OUT/$VERSION" "sing-box-extended $VERSION - architectures"

cat > "$OUT/index.md" <<EOF
---
layout: default
title: sing-box-extended apk feed
---

# sing-box-extended apk feed

Signed feed of the [sing-box-extended](https://github.com/shtorm-7/sing-box-extended)
fork, packed as drop-in \`sing-box\` for OpenWrt (apk).

## Install

\`\`\`sh
ARCH=\$(apk --print-arch)
wget -O /etc/apk/keys/luci-singbox.pem ${PAGES_URL}/luci-singbox.pem
echo "${PAGES_URL}/sing-box-extended/${VERSION}/\$ARCH/packages.adb" \\
  > /etc/apk/repositories.d/sing-box-extended.list
apk update && apk add sing-box-extended      # or sing-box-extended-upx
\`\`\`

## Browse

- [${VERSION}](${VERSION}/) — packages by architecture
EOF
echo "feed built at $OUT"
