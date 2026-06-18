#!/bin/sh
# Build a signed, browsable apk feed for sing-box-extended, laid out as a SIBLING
# of the luci-singbox feed under the SAME OpenWrt-minor tree:
#
#   <out>/<owrt_minor>/<arch>/sing-box/{<name>-<ver>.apk, packages.adb, index.md}
#
# The output is published to the gh-pages ROOT with keep_files:true, so it merges
# into 25.12/<arch>/ right next to luci-singbox/ WITHOUT touching the shared
# browse pages (25.12/<arch>/index.md, 25.12/index.md, root index.md, pubkey) —
# those are owned by scripts/build-feed.sh on main, which links to sing-box/ so
# it shows on the landing.
#
# Usage: feed.sh <owrt_minor> <apk_version> <dist_dir> <out_dir>
#   owrt_minor   OpenWrt release line for the top path segment, e.g. 25.12
#                (same segment the luci-singbox feed uses — NOT the apk version)
#   apk_version  package version embedded in the dist filenames, e.g.
#                1.13.12_p002004001 (used to parse the arch off each filename)
#   dist_dir     dir with sing-box-extended_<ver>_<arch>.apk + the -upx variants
#   out_dir      output dir (wiped); its CONTENTS are published to the gh-pages root
#
# Env: APK_BIN (required), FEED_SIGN_KEY (optional; unsigned if empty),
#      PAGES_URL (default https://janeblower.github.io/luci-singbox)
set -eu
MINOR="${1:?usage: feed.sh <owrt_minor> <apk_version> <dist_dir> <out_dir>}"
VERSION="${2:?}"; DIST="${3:?}"; OUT="${4:?}"
: "${APK_BIN:?APK_BIN required}"
# Absolutize APK_BIN: the signing loop runs `apk mkndx` inside `( cd "$d" && ... )`,
# so a relative APK_BIN (e.g. CI's sdk/.../bin/apk) would not resolve after the cd.
case "$APK_BIN" in
  /*) ;;                                                              # already absolute
  */*) APK_BIN="$(cd "$(dirname "$APK_BIN")" && pwd)/$(basename "$APK_BIN")" ;;
  *) ;;                                                               # bare name -> PATH
esac
PAGES_URL="${PAGES_URL:-https://janeblower.github.io/luci-singbox}"
REPO="sing-box"   # leaf dir name, sibling of luci-singbox/

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

rm -rf "$OUT"
found=0
for apk in "$DIST"/sing-box-extended_"${VERSION}"_*.apk; do
  [ -e "$apk" ] || continue
  base="$(basename "$apk")"; arch="${base#sing-box-extended_${VERSION}_}"; arch="${arch%.apk}"
  d="$OUT/$MINOR/$arch/$REPO"; mkdir -p "$d"
  copy_pkg "$apk" "$d"
  upx="$DIST/sing-box-extended-upx_${VERSION}_${arch}.apk"
  [ -f "$upx" ] || { echo "missing UPX apk for $arch: $upx" >&2; exit 1; }
  copy_pkg "$upx" "$d"
  if [ -n "${FEED_SIGN_KEY:-}" ]; then
    ( cd "$d" && "$APK_BIN" mkndx --allow-untrusted --sign-key "$FEED_SIGN_KEY" -o packages.adb ./*.apk )
  else
    ( cd "$d" && "$APK_BIN" mkndx --allow-untrusted -o packages.adb ./*.apk )
  fi
  # Own leaf-dir index (install snippet + package list). The SHARED parent browse
  # pages belong to main's build-feed.sh — do not emit them here.
  {
    printf -- '---\nlayout: default\ntitle: %s\n---\n\n' "sing-box ($arch, OpenWrt $MINOR)"
    printf -- '# sing-box (extended) — %s\n\n' "$arch"
    printf -- 'Drop-in `sing-box` ([extended fork](https://github.com/shtorm-7/sing-box-extended)) for OpenWrt %s.\n\n' "$MINOR"
    printf -- '## Install\n\n```sh\n'
    printf -- 'wget -O /etc/apk/keys/luci-singbox.pem %s/luci-singbox.pem\n' "$PAGES_URL"
    printf -- 'echo "%s/%s/%s/sing-box/packages.adb" \\\n' "$PAGES_URL" "$MINOR" "$arch"
    printf -- '  > /etc/apk/repositories.d/sing-box-extended.list\n'
    printf -- 'apk update && apk add sing-box-extended      # or sing-box-extended-upx\n'
    printf -- '```\n\n## Packages\n\n'
    for f in "$d"/*.apk; do printf -- '- [%s](%s)\n' "$(basename "$f")" "$(basename "$f")"; done
  } > "$d/index.md"
  found=1
done
[ "$found" = 1 ] || { echo "no sing-box-extended_${VERSION}_*.apk in $DIST" >&2; exit 1; }
echo "feed built at $OUT ($MINOR/<arch>/$REPO)"
