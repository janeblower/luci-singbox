#!/usr/bin/env bash
# Build the luci-app-singbox-ui .apk directly via the OpenWrt SDK's host `apk`
# tool, skipping the full SDK build orchestration. The package is noarch
# (LUCI_PKGARCH:=all), so no cross-compilation is needed — only po2lmo (built
# once from the luci feed) and apk-mkpkg.
#
# Usage: build-apk.sh <version> [output_dir]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PKG_NAME="luci-app-singbox-ui"
PKG_DESC="LuCI support for singbox-ui"
PKG_DEPENDS="libc luci-base nftables sing-box jq curl"
PKG_LICENSE="GPL-2.0-or-later"
PKG_URL="https://github.com/Jyn/luci-app-sing-box"
PKG_MAINTAINER="Jyn"
PKG_CONFFILE="/etc/config/singbox-ui"

VERSION="${1:-}"
OUTPUT_DIR="${2:-$ROOT_DIR/dist}"
if [ -z "$VERSION" ]; then
  echo "Usage: $0 <version> [output_dir]" >&2
  exit 1
fi

SDK_URL="${SDK_URL:-https://downloads.openwrt.org/releases/25.12.3/targets/x86/64/openwrt-sdk-25.12.3-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst}"
SDK_CACHE_DIR="${SDK_CACHE_DIR:-$HOME/.cache/luci-app-singbox-ui/openwrt-sdk}"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/.build}"
SDK_DIR="$WORK_DIR/sdk"

mkdir -p "$SDK_CACHE_DIR" "$WORK_DIR" "$OUTPUT_DIR"

sdk_tarball="$SDK_CACHE_DIR/$(basename "$SDK_URL")"
if [ ! -f "$sdk_tarball" ]; then
  echo ">>> Downloading SDK: $SDK_URL"
  wget -q --show-progress -O "$sdk_tarball.part" "$SDK_URL"
  mv "$sdk_tarball.part" "$sdk_tarball"
fi

marker="$SDK_DIR/.sdk-url"
if [ ! -f "$marker" ] || [ "$(cat "$marker" 2>/dev/null || true)" != "$SDK_URL" ]; then
  echo ">>> Extracting SDK"
  rm -rf "$SDK_DIR"
  tmp="$(mktemp -d "$WORK_DIR/.sdk.XXXXXX")"
  tar --zstd -xf "$sdk_tarball" -C "$tmp"
  root_dir="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  mv "$root_dir" "$SDK_DIR"
  rmdir "$tmp" 2>/dev/null || true
  echo "$SDK_URL" > "$marker"
fi

APK_BIN="$SDK_DIR/staging_dir/host/bin/apk"
[ -x "$APK_BIN" ] || { echo "apk host tool missing at $APK_BIN" >&2; exit 1; }

PO2LMO_BIN="$SDK_DIR/staging_dir/hostpkg/bin/po2lmo"
if [ ! -x "$PO2LMO_BIN" ]; then
  echo ">>> Preparing po2lmo (from luci feed)"
  if [ ! -d "$SDK_DIR/feeds/luci" ]; then
    (cd "$SDK_DIR" && ./scripts/feeds update luci >/dev/null)
  fi
  luci_src="$SDK_DIR/feeds/luci/modules/luci-base/src"
  make -C "$luci_src" po2lmo >/dev/null
  mkdir -p "$(dirname "$PO2LMO_BIN")"
  install -m0755 "$luci_src/po2lmo" "$PO2LMO_BIN"
fi

echo ">>> Assembling package root"
PKG_SRC="$ROOT_DIR/luci-app-singbox-ui"
PKG_ROOT="$WORK_DIR/pkg-root"
SCRIPTS_DIR="$WORK_DIR/scripts"
rm -rf "$PKG_ROOT" "$SCRIPTS_DIR"

install -d \
  "$PKG_ROOT/etc/config" \
  "$PKG_ROOT/etc/uci-defaults" \
  "$PKG_ROOT/etc/singbox-ui" \
  "$PKG_ROOT/etc/init.d" \
  "$PKG_ROOT/usr/libexec/rpcd" \
  "$PKG_ROOT/usr/share/luci/menu.d" \
  "$PKG_ROOT/usr/share/rpcd/acl.d" \
  "$PKG_ROOT/usr/share/singbox-ui" \
  "$PKG_ROOT/www/luci-static/resources/view/singbox-ui" \
  "$PKG_ROOT/usr/lib/lua/luci/i18n"

install -m 0644 "$PKG_SRC/root/etc/config/singbox-ui"                        "$PKG_ROOT/etc/config/singbox-ui"
install -m 0755 "$PKG_SRC/root/etc/uci-defaults/99-luci-app-singbox-ui"      "$PKG_ROOT/etc/uci-defaults/99-luci-app-singbox-ui"
install -m 0755 "$PKG_SRC/root/etc/singbox-ui/nftables.sh"                   "$PKG_ROOT/etc/singbox-ui/nftables.sh"
install -m 0755 "$PKG_SRC/root/etc/init.d/singbox-ui"                        "$PKG_ROOT/etc/init.d/singbox-ui"
install -m 0755 "$PKG_SRC/root/usr/libexec/rpcd/singbox-ui"                  "$PKG_ROOT/usr/libexec/rpcd/singbox-ui"
install -m 0644 "$PKG_SRC/root/usr/share/luci/menu.d/luci-app-singbox-ui.json" "$PKG_ROOT/usr/share/luci/menu.d/luci-app-singbox-ui.json"
install -m 0644 "$PKG_SRC/root/usr/share/rpcd/acl.d/luci-app-singbox-ui.json"  "$PKG_ROOT/usr/share/rpcd/acl.d/luci-app-singbox-ui.json"
install -m 0644 "$PKG_SRC/root/usr/share/singbox-ui/generate.uc"             "$PKG_ROOT/usr/share/singbox-ui/generate.uc"
install -m 0755 "$PKG_SRC/root/usr/share/singbox-ui/fetch_subscriptions.sh"  "$PKG_ROOT/usr/share/singbox-ui/fetch_subscriptions.sh"
install -m 0755 "$PKG_SRC/root/usr/share/singbox-ui/fetch_rulesets.sh"       "$PKG_ROOT/usr/share/singbox-ui/fetch_rulesets.sh"
install -m 0755 "$PKG_SRC/root/usr/share/singbox-ui/refresh.sh"              "$PKG_ROOT/usr/share/singbox-ui/refresh.sh"
install -m 0644 "$PKG_SRC/htdocs/luci-static/resources/view/singbox-ui/main.js" "$PKG_ROOT/www/luci-static/resources/view/singbox-ui/main.js"

if [ -f "$PKG_SRC/po/ru/luci-app-singbox-ui.po" ]; then
  "$PO2LMO_BIN" "$PKG_SRC/po/ru/luci-app-singbox-ui.po" \
    "$PKG_ROOT/usr/lib/lua/luci/i18n/luci-app-singbox-ui.ru.lmo"
fi

list_dir="$PKG_ROOT/lib/apk/packages"
mkdir -p "$list_dir"
(cd "$PKG_ROOT" && find . -type f ! -path './lib/apk/packages/*' \
   | LC_ALL=C sort | sed 's#^\./#/#') > "$list_dir/${PKG_NAME}.list"
conffile_hash="$(sha256sum "$PKG_ROOT$PKG_CONFFILE" | awk '{print $1}')"
printf '%s\n' "$PKG_CONFFILE" > "$list_dir/${PKG_NAME}.conffiles"
printf '%s %s\n' "$PKG_CONFFILE" "$conffile_hash" > "$list_dir/${PKG_NAME}.conffiles_static"

mkdir -p "$SCRIPTS_DIR"
cat > "$SCRIPTS_DIR/post-install.sh" <<'EOF'
#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_postinst $0 $@
[ -n "${IPKG_INSTROOT}" ] || {
  rm -f /tmp/luci-indexcache.*
  rm -rf /tmp/luci-modulecache/
  killall -HUP rpcd 2>/dev/null
}
exit 0
EOF
cat > "$SCRIPTS_DIR/pre-deinstall.sh" <<'EOF'
#!/bin/sh
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_prerm $0 $@
exit 0
EOF
cat > "$SCRIPTS_DIR/post-upgrade.sh" <<'EOF'
#!/bin/sh
export PKG_UPGRADE=1
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_postinst $0 $@
[ -n "${IPKG_INSTROOT}" ] || {
  rm -f /tmp/luci-indexcache.*
  rm -rf /tmp/luci-modulecache/
  killall -HUP rpcd 2>/dev/null
}
exit 0
EOF
chmod 0755 "$SCRIPTS_DIR"/*.sh

echo ">>> Building apk package"
OUT="$OUTPUT_DIR/${PKG_NAME}_${VERSION}.apk"
rm -f "$OUT"

mkpkg_cmd() {
  "$APK_BIN" mkpkg \
    --files "$PKG_ROOT" \
    --output "$OUT" \
    -I "name:$PKG_NAME" \
    -I "version:$VERSION" \
    -I "description:$PKG_DESC" \
    -I "arch:all" \
    -I "license:$PKG_LICENSE" \
    -I "origin:$PKG_NAME" \
    -I "maintainer:$PKG_MAINTAINER" \
    -I "url:$PKG_URL" \
    -I "depends:$PKG_DEPENDS" \
    -s "post-install:$SCRIPTS_DIR/post-install.sh" \
    -s "pre-deinstall:$SCRIPTS_DIR/pre-deinstall.sh" \
    -s "post-upgrade:$SCRIPTS_DIR/post-upgrade.sh"
}

if [ "$(id -u)" -eq 0 ]; then
  chown -R 0:0 "$PKG_ROOT" "$SCRIPTS_DIR"
  mkpkg_cmd
elif command -v unshare >/dev/null 2>&1 && unshare -r true >/dev/null 2>&1; then
  export PKG_ROOT SCRIPTS_DIR OUT APK_BIN PKG_NAME VERSION PKG_DESC PKG_LICENSE PKG_URL PKG_MAINTAINER PKG_DEPENDS
  unshare -r sh -c '
    chown -R 0:0 "$PKG_ROOT" "$SCRIPTS_DIR"
    "$APK_BIN" mkpkg \
      --files "$PKG_ROOT" \
      --output "$OUT" \
      -I "name:$PKG_NAME" \
      -I "version:$VERSION" \
      -I "description:$PKG_DESC" \
      -I "arch:all" \
      -I "license:$PKG_LICENSE" \
      -I "origin:$PKG_NAME" \
      -I "maintainer:$PKG_MAINTAINER" \
      -I "url:$PKG_URL" \
      -I "depends:$PKG_DEPENDS" \
      -s "post-install:$SCRIPTS_DIR/post-install.sh" \
      -s "pre-deinstall:$SCRIPTS_DIR/pre-deinstall.sh" \
      -s "post-upgrade:$SCRIPTS_DIR/post-upgrade.sh"
  '
else
  export PKG_ROOT SCRIPTS_DIR OUT APK_BIN PKG_NAME VERSION PKG_DESC PKG_LICENSE PKG_URL PKG_MAINTAINER PKG_DEPENDS
  fakeroot sh -c '
    chown -R 0:0 "$PKG_ROOT" "$SCRIPTS_DIR"
    "$APK_BIN" mkpkg \
      --files "$PKG_ROOT" \
      --output "$OUT" \
      -I "name:$PKG_NAME" \
      -I "version:$VERSION" \
      -I "description:$PKG_DESC" \
      -I "arch:all" \
      -I "license:$PKG_LICENSE" \
      -I "origin:$PKG_NAME" \
      -I "maintainer:$PKG_MAINTAINER" \
      -I "url:$PKG_URL" \
      -I "depends:$PKG_DEPENDS" \
      -s "post-install:$SCRIPTS_DIR/post-install.sh" \
      -s "pre-deinstall:$SCRIPTS_DIR/pre-deinstall.sh" \
      -s "post-upgrade:$SCRIPTS_DIR/post-upgrade.sh"
  '
fi

echo ">>> Verifying package metadata"
"$APK_BIN" adbdump "$OUT" | grep -E "^  (name|version|arch): " || true

echo ">>> Built: $OUT"
