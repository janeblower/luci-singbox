#!/bin/sh
# Local validation harness for build.sh. Run: sh test-build.sh <case>
set -eu
cd "$(dirname "$0")"
SB_BUILD_LIB=1 . ./build.sh   # source funcs without running main (POSIX-sh compatible)

fail=0
check() { # check <desc> <actual> <expected>
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1: got [$2] want [$3]"; fail=1; fi
}

check "strip-v plain"        "$(to_apk_version v1.2.3)"                 "1.2.3"
check "extended mapping"     "$(to_apk_version v1.13.12-extended-2.4.1)" "1.13.12_p002004001"
check "extended two-comp"    "$(to_apk_version v1.13.12-extended-2.10)"  "1.13.12_p002010"
check "already valid -r"     "$(to_apk_version v1.2.3-r4)"             "1.2.3-r4"
check "abi count"            "$(abi_list | wc -w | tr -d ' ')"        "5"
check "amd64 arches"         "$(arches_for amd64)"                    "x86_64"
check "armv7 arch count"     "$(arches_for armv7 | wc -w | tr -d ' ')" "9"

[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }

# Run with: sh test-build.sh compile   (needs Go + network + SRC_DIR)
if [ "${1:-}" = "compile" ]; then
  : "${SRC_DIR:?set SRC_DIR to a checked-out fork}"
  tag="${TAG:-v1.13.12-extended-2.4.1}"
  out="$(mktemp -d)/sing-box"
  compile_abi amd64 "$SRC_DIR" "$tag" "$out"
  [ -x "$out" ] || { echo "FAIL - binary not produced"; exit 1; }
  ver="$("$out" version 2>/dev/null | head -n1)"
  echo "$ver" | grep -q "sing-box version" || { echo "FAIL - version output: $ver"; exit 1; }
  echo "ok   - compile amd64 + version: $ver"
  exit 0
fi

# Run with: sh test-build.sh pkg   (needs Go + APK_BIN + SRC_DIR)
if [ "${1:-}" = "pkg" ]; then
  : "${SRC_DIR:?}"; : "${APK_BIN:?set APK_BIN to apk-tools 3.0.5+}"
  tag="${TAG:-v1.13.12-extended-2.4.1}"; ver="$(to_apk_version "$tag")"
  work="$(mktemp -d)"; bin="$work/sing-box"; root="$work/root"; apk="$work/out.apk"
  compile_abi amd64 "$SRC_DIR" "$tag" "$bin"
  populate_root "$SRC_DIR" "$bin" "$root"
  ( cd "$root" && chmod -R a+rX . )
  mkpkg_one "$PKG_NAME" "$PKG_NAME_UPX" "$ver" "x86_64" "$root" "$SRC_DIR" "$apk"
  d="$("$APK_BIN" adbdump "$apk")"
  echo "$d" | grep -qE "^  name: $PKG_NAME$"          || { echo "FAIL name";     exit 1; }
  echo "$d" | grep -qE "^  version: $ver$"            || { echo "FAIL version";  exit 1; }
  echo "$d" | grep -qE "arch: x86_64"                 || { echo "FAIL arch";     exit 1; }
  echo "$d" | grep -q  "sing-box=$ver"                || { echo "FAIL provides"; exit 1; }
  echo "$d" | grep -q  "firewall4"                    || { echo "FAIL depends";  exit 1; }
  echo "$d" | grep -q  "$PKG_NAME_UPX"                || { echo "FAIL conflict-sibling"; exit 1; }
  "$APK_BIN" adbdump "$apk" | grep -q "usr/bin/sing-box" \
     || tar -tzf "$apk" 2>/dev/null | grep -q "usr/bin/sing-box" || { echo "FAIL binary path"; exit 1; }
  echo "ok   - pkg x86_64 metadata + drop-in layout"
  exit 0
fi

# Run with: sh test-build.sh all   (heavy: 5 Go builds + 40 apk; needs Go+APK_BIN+UPX+SRC_DIR)
if [ "${1:-}" = "all" ]; then
  : "${SRC_DIR:?}"; : "${APK_BIN:?}"
  tag="${TAG:-v1.13.12-extended-2.4.1}"; ver="$(to_apk_version "$tag")"
  out="$(mktemp -d)/dist"
  APK_BIN="$APK_BIN" sh ./build.sh "$tag" "$SRC_DIR" "$out"
  n="$(ls "$out"/*.apk | wc -l | tr -d ' ')"
  [ "$n" = 40 ] || { echo "FAIL - expected 40 apk, got $n"; exit 1; }
  ls "$out/sing-box-extended_${ver}_x86_64.apk" >/dev/null     || { echo "FAIL normal x86_64"; exit 1; }
  ls "$out/sing-box-extended-upx_${ver}_mips_24kc.apk" >/dev/null || { echo "FAIL upx mips"; exit 1; }
  echo "ok   - full matrix: 40 apk"
  exit 0
fi

# Run with: sh test-build.sh feed   (needs APK_BIN; reuses dist from `all` via DIST env)
if [ "${1:-}" = "feed" ]; then
  : "${APK_BIN:?}"; : "${DIST:?set DIST to a build.sh out_dir with 40 apk}"
  tag="${TAG:-v1.13.12-extended-2.4.1}"; ver="$(to_apk_version "$tag")"
  out="$(mktemp -d)/feed"
  APK_BIN="$APK_BIN" PAGES_URL="https://example.test/luci-singbox" \
    sh ./feed.sh "$ver" "$DIST" "$out"
  ad="$out/$ver/x86_64/packages.adb"; [ -f "$ad" ] || { echo "FAIL no packages.adb"; exit 1; }
  ls "$out/$ver/x86_64/sing-box-extended-$ver.apk" >/dev/null     || { echo "FAIL renamed normal"; exit 1; }
  ls "$out/$ver/x86_64/sing-box-extended-upx-$ver.apk" >/dev/null || { echo "FAIL renamed upx"; exit 1; }
  "$APK_BIN" adbdump "$ad" | grep -q "sing-box-extended"          || { echo "FAIL index content"; exit 1; }
  [ -f "$out/index.md" ] && [ -f "$out/$ver/index.md" ]          || { echo "FAIL index.md"; exit 1; }
  grep -q "example.test/luci-singbox" "$out/index.md"            || { echo "FAIL PAGES_URL"; exit 1; }
  grep -q "packages.adb" "$out/index.md"                         || { echo "FAIL install snippet"; exit 1; }
  echo "ok   - feed tree built + signed-index structure"
  exit 0
fi
