#!/bin/sh
# Cross-compile sing-box-extended and pack drop-in OpenWrt apks (normal + UPX).
#
# Usage:  build.sh <tag> <src_dir> <out_dir>
#   tag       upstream git tag, e.g. v1.13.12-extended-2.4.1
#   src_dir   checked-out fork source (contains cmd/, release/config/, ...)
#   out_dir   dist dir for the produced *.apk (created)
# Sourcing for tests:  . ./build.sh --lib   (defines funcs, runs nothing)
#
# Env: APK_BIN (required for packaging), UPX_BIN (default upx), GO (default go).
set -eu

GO="${GO:-go}"
UPX_BIN="${UPX_BIN:-upx}"

GO_TAGS="with_gvisor,with_dhcp,with_wireguard,with_reality_server,with_clash_api,with_quic,with_utls,with_ech"

PKG_NAME="sing-box-extended"
PKG_NAME_UPX="sing-box-extended-upx"
PKG_DESC="sing-box (extended fork by shtorm-7) — universal proxy platform"
PKG_LICENSE="GPL-3.0-or-later"
PKG_MAINTAINER="Jyn"
PKG_URL="https://github.com/shtorm-7/sing-box-extended"
PKG_DEPENDS="ca-bundle kmod-inet-diag kmod-tun firewall4"

# --- ABI map (single source of truth; mirrors scripts/build-apk.sh on main) ---
abi_list() { echo "amd64 arm64 armv7 mipsel mips"; }

goenv_for() { # goenv_for <abi> -> space-separated KEY=VAL pairs
  case "$1" in
    amd64)  echo "GOARCH=amd64" ;;
    arm64)  echo "GOARCH=arm64" ;;
    armv7)  echo "GOARCH=arm GOARM=7" ;;
    mipsel) echo "GOARCH=mipsle GOMIPS=softfloat" ;;
    mips)   echo "GOARCH=mips GOMIPS=softfloat" ;;
    *) echo "unknown abi: $1" >&2; return 1 ;;
  esac
}

arches_for() { # arches_for <abi> -> space-separated exact OpenWrt arches
  case "$1" in
    amd64)  echo "x86_64" ;;
    arm64)  echo "aarch64_cortex-a53 aarch64_cortex-a72 aarch64_cortex-a76 aarch64_generic" ;;
    armv7)  echo "arm_cortex-a5_vfpv4 arm_cortex-a7 arm_cortex-a7_neon-vfpv4 arm_cortex-a7_vfpv4 arm_cortex-a8_vfpv3 arm_cortex-a9 arm_cortex-a9_neon arm_cortex-a9_vfpv3-d16 arm_cortex-a15_neon-vfpv4" ;;
    mipsel) echo "mipsel_24kc mipsel_24kc_24kf mipsel_74kc mipsel_mips32" ;;
    mips)   echo "mips_24kc mips_mips32" ;;
    *) echo "unknown abi: $1" >&2; return 1 ;;
  esac
}

# to_apk_version <tag> -> apk-valid version string.
# Strips leading 'v'. Maps '<base>-extended-<ext>' to '<base>_p<packed>' where
# each dot-component of <ext> is zero-padded to 3 digits and concatenated.
# A tag without '-extended-' is returned as-is (already apk-valid by assumption).
to_apk_version() {
  v="${1#v}"
  case "$v" in
    *-extended-*)
      base="${v%-extended-*}"
      ext="${v##*-extended-}"
      packed=""
      oldifs="$IFS"; IFS='.'
      for c in $ext; do packed="${packed}$(printf '%03d' "$c")"; done
      IFS="$oldifs"
      echo "${base}_p${packed}"
      ;;
    *) echo "$v" ;;
  esac
}

# compile_abi <abi> <src_dir> <tag> <dest_binary>
compile_abi() {
  _abi="$1"; _src="$2"; _tag="$3"; _dst="$4"
  _ver="$(to_apk_version "$_tag")"   # not used for ldflags; upstream uses raw tag
  _rawver="${_tag#v}"
  mkdir -p "$(dirname "$_dst")"
  # shellcheck disable=SC2046  # intentional word-split of goenv pairs
  env CGO_ENABLED=0 GOOS=linux $(goenv_for "$_abi") \
    "$GO" -C "$_src" build -trimpath \
      -ldflags "-X 'github.com/sagernet/sing-box/constant.Version=${_rawver}' -s -w -buildid=" \
      -tags "$GO_TAGS" \
      -o "$_dst" ./cmd/sing-box
}

# populate_root <src_dir> <binary> <root_dir>
#   Lay down the full drop-in file set (binary + init.d + config + completions +
#   license + conffiles markers). Completions are best-effort (skipped if absent).
populate_root() {
  _src="$1"; _bin="$2"; _root="$3"
  rm -rf "$_root"
  install -D -m0755 "$_bin"                          "$_root/usr/bin/sing-box"
  install -D -m0755 "$_src/release/config/openwrt.init" "$_root/etc/init.d/sing-box"
  install -D -m0644 "$_src/release/config/openwrt.conf" "$_root/etc/config/sing-box"
  install -D -m0644 "$_src/release/config/config.json"  "$_root/etc/sing-box/config.json"
  install -D -m0644 "$_src/release/config/openwrt.keep" "$_root/lib/upgrade/keep.d/sing-box"
  install -D -m0644 "$_src/LICENSE"                  "$_root/usr/share/licenses/sing-box/LICENSE"
  for _c in bash fish zsh; do
    case "$_c" in
      bash) _dst="$_root/usr/share/bash-completion/completions/sing-box.bash" ;;
      fish) _dst="$_root/usr/share/fish/vendor_completions.d/sing-box.fish" ;;
      zsh)  _dst="$_root/usr/share/zsh/site-functions/_sing-box" ;;
    esac
    if [ -f "$_src/release/completions/sing-box.$_c" ]; then
      install -D -m0644 "$_src/release/completions/sing-box.$_c" "$_dst"
    fi
  done
  write_conffiles "$_root" "sing-box" /etc/config/sing-box /etc/sing-box/config.json
}

# write_conffiles <root> <pkgname> <conffile...>
#   Emit OpenWrt apk conffile markers + the package file list (mirrors
#   scripts/build-apk.sh write_pkg_list + conffiles on main).
write_conffiles() {
  _root="$1"; _name="$2"; shift 2
  _ld="$_root/lib/apk/packages"; mkdir -p "$_ld"
  : > "$_ld/${_name}.conffiles"; : > "$_ld/${_name}.conffiles_static"
  for _f in "$@"; do
    printf '%s\n' "$_f" >> "$_ld/${_name}.conffiles"
    _h="$(sha256sum "$_root$_f" | awk '{print $1}')"
    printf '%s %s\n' "$_f" "$_h" >> "$_ld/${_name}.conffiles_static"
  done
  ( cd "$_root" && find . -type f ! -path './lib/apk/packages/*' \
      | LC_ALL=C sort | sed 's#^\./#/#' ) > "$_ld/${_name}.list"
}

# mkpkg_one <name> <sibling> <version> <exact_arch> <root> <src_dir> <out.apk>
#   apk mkpkg for one drop-in package. provides sing-box (versioned), conflicts
#   the stock sing-box AND the sibling variant. Maps openwrt.prerm -> pre-deinstall.
#   Probes whether mkpkg tolerates -I "conflicts:" (as scripts/build-apk.sh does).
mkpkg_one() {
  _name="$1"; _sib="$2"; _ver="$3"; _arch="$4"; _root="$5"; _src="$6"; _out="$7"
  : "${APK_BIN:?APK_BIN required}"
  _prerm="$_src/release/config/openwrt.prerm"
  set -- \
    --files "$_root" --output "$_out" \
    -I "name:$_name" -I "version:$_ver" -I "description:$PKG_DESC" \
    -I "arch:$_arch" -I "license:$PKG_LICENSE" -I "origin:$_name" \
    -I "maintainer:$PKG_MAINTAINER" -I "url:$PKG_URL" \
    -I "depends:$PKG_DEPENDS" -I "provides:sing-box=$_ver"
  [ -f "$_prerm" ] && set -- "$@" -s "pre-deinstall:$_prerm"
  if "$APK_BIN" mkpkg --help 2>&1 | grep -q 'conflicts'; then
    "$APK_BIN" mkpkg "$@" -I "conflicts:sing-box" -I "conflicts:$_sib"
  else
    echo "FATAL: apk mkpkg lacks 'conflicts:' support; mutual exclusion is mandatory" >&2
    exit 1
  fi
}

# compress_upx <in_binary> <out_binary>
compress_upx() {
  cp "$1" "$2"
  "$UPX_BIN" --best --lzma "$2" >/dev/null
}

# build_all <tag> <src_dir> <out_dir>
build_all() {
  _tag="$1"; _src="$2"; _out="$3"; _ver="$(to_apk_version "$_tag")"
  mkdir -p "$_out"; _tmp="$(mktemp -d)"
  for _abi in $(abi_list); do
    _bin="$_tmp/$_abi/sing-box";  _ubin="$_tmp/$_abi/sing-box.upx"
    compile_abi "$_abi" "$_src" "$_tag" "$_bin"
    compress_upx "$_bin" "$_ubin"
    for _arch in $(arches_for "$_abi"); do
      # normal
      _root="$_tmp/root-$_arch"; populate_root "$_src" "$_bin" "$_root"
      chmod -R a+rX "$_root"
      mkpkg_one "$PKG_NAME" "$PKG_NAME_UPX" "$_ver" "$_arch" "$_root" "$_src" \
        "$_out/${PKG_NAME}_${_ver}_${_arch}.apk"
      # upx
      _uroot="$_tmp/uroot-$_arch"; populate_root "$_src" "$_ubin" "$_uroot"
      chmod -R a+rX "$_uroot"
      mkpkg_one "$PKG_NAME_UPX" "$PKG_NAME" "$_ver" "$_arch" "$_uroot" "$_src" \
        "$_out/${PKG_NAME_UPX}_${_ver}_${_arch}.apk"
    done
  done
  echo ">>> built $(ls "$_out"/*.apk | wc -l) apk into $_out"
}

# --- entrypoint ---
# When sourced for testing (. ./build.sh --lib OR SB_BUILD_LIB=1 . ./build.sh),
# stop here so the caller gets all function definitions without executing a build.
# Note: POSIX sh (dash) does NOT forward args to sourced scripts, so we check both
# the positional arg (works in bash) and SB_BUILD_LIB env (works in all POSIX sh).
if [ "${1:-}" = "--lib" ] || [ "${SB_BUILD_LIB:-}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi
case "${1:-}" in
  "") echo "usage: build.sh <tag> <src_dir> <out_dir>" >&2; exit 2 ;;
  *) build_all "$1" "$2" "$3" ;;
esac
