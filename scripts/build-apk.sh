#!/usr/bin/env bash
# Build the luci-app-singbox-ui .apk packages directly via the OpenWrt SDK's
# host `apk` tool, skipping the full SDK build orchestration. Packages are
# noarch (LUCI_PKGARCH:=all), so no cross-compilation is needed — only po2lmo
# (built once from the luci feed) and apk-mkpkg.
#
# Produces two packages:
#   - luci-app-singbox-ui_<version>.apk        main app (no translations)
#   - luci-i18n-singbox-ui-ru_<version>.apk    Russian translation pack
#
# Usage: build-apk.sh <version> [output_dir]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="luci-app-singbox-ui"
APP_DESC="LuCI support for singbox-ui"
APP_DEPENDS="libc luci-base nftables sing-box jq curl"
APP_CONFFILE="/etc/config/singbox-ui"

I18N_NAME="luci-i18n-singbox-ui-ru"
I18N_DESC="Translation for luci-app-singbox-ui — Русский (Russian)"
I18N_DEPENDS="libc $APP_NAME"

PKG_LICENSE="GPL-2.0-or-later"
PKG_URL="https://github.com/Jyn/luci-app-sing-box"
PKG_MAINTAINER="Jyn"

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

PKG_SRC="$ROOT_DIR/luci-app-singbox-ui"

# ---------------------------------------------------------------------------
# Main package root
# ---------------------------------------------------------------------------
APP_ROOT="$WORK_DIR/pkg-root-app"
APP_SCRIPTS="$WORK_DIR/scripts-app"
rm -rf "$APP_ROOT" "$APP_SCRIPTS"

install -d \
  "$APP_ROOT/etc/config" \
  "$APP_ROOT/etc/uci-defaults" \
  "$APP_ROOT/etc/init.d" \
  "$APP_ROOT/usr/libexec/rpcd" \
  "$APP_ROOT/usr/share/luci/menu.d" \
  "$APP_ROOT/usr/share/rpcd/acl.d" \
  "$APP_ROOT/usr/share/singbox-ui" \
  "$APP_ROOT/usr/share/singbox-ui/lib" \
  "$APP_ROOT/www/luci-static/resources/view/singbox-ui"

install -m 0644 "$PKG_SRC/root/etc/config/singbox-ui"                        "$APP_ROOT/etc/config/singbox-ui"
install -m 0755 "$PKG_SRC/root/etc/uci-defaults/99-luci-app-singbox-ui"      "$APP_ROOT/etc/uci-defaults/99-luci-app-singbox-ui"
install -m 0755 "$PKG_SRC/root/etc/init.d/singbox-ui"                        "$APP_ROOT/etc/init.d/singbox-ui"
install -m 0755 "$PKG_SRC/root/usr/libexec/rpcd/singbox-ui"                  "$APP_ROOT/usr/libexec/rpcd/singbox-ui"
install -m 0644 "$PKG_SRC/root/usr/share/luci/menu.d/luci-app-singbox-ui.json" "$APP_ROOT/usr/share/luci/menu.d/luci-app-singbox-ui.json"
install -m 0644 "$PKG_SRC/root/usr/share/rpcd/acl.d/luci-app-singbox-ui.json"  "$APP_ROOT/usr/share/rpcd/acl.d/luci-app-singbox-ui.json"
install -m 0644 "$PKG_SRC/root/usr/share/singbox-ui/generate.uc"             "$APP_ROOT/usr/share/singbox-ui/generate.uc"
install -m 0644 "$PKG_SRC/root/usr/share/singbox-ui/subscription.uc"         "$APP_ROOT/usr/share/singbox-ui/subscription.uc"
install -m 0644 "$PKG_SRC/root/usr/share/singbox-ui/nftables.uc"             "$APP_ROOT/usr/share/singbox-ui/nftables.uc"
for lib_uc in "$PKG_SRC"/root/usr/share/singbox-ui/lib/*.uc; do
  install -m 0644 "$lib_uc" "$APP_ROOT/usr/share/singbox-ui/lib/$(basename "$lib_uc")"
done
install -m 0644 "$PKG_SRC/htdocs/luci-static/resources/view/singbox-ui/main.js" "$APP_ROOT/www/luci-static/resources/view/singbox-ui/main.js"

list_dir="$APP_ROOT/lib/apk/packages"
mkdir -p "$list_dir"
(cd "$APP_ROOT" && find . -type f ! -path './lib/apk/packages/*' \
   | LC_ALL=C sort | sed 's#^\./#/#') > "$list_dir/${APP_NAME}.list"
conffile_hash="$(sha256sum "$APP_ROOT$APP_CONFFILE" | awk '{print $1}')"
printf '%s\n' "$APP_CONFFILE" > "$list_dir/${APP_NAME}.conffiles"
printf '%s %s\n' "$APP_CONFFILE" "$conffile_hash" > "$list_dir/${APP_NAME}.conffiles_static"

mkdir -p "$APP_SCRIPTS"
cat > "$APP_SCRIPTS/post-install.sh" <<'EOF'
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
cat > "$APP_SCRIPTS/pre-deinstall.sh" <<'EOF'
#!/bin/sh
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_prerm $0 $@
exit 0
EOF
cat > "$APP_SCRIPTS/post-upgrade.sh" <<'EOF'
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
chmod 0755 "$APP_SCRIPTS"/*.sh

# ---------------------------------------------------------------------------
# i18n-ru package root
# ---------------------------------------------------------------------------
I18N_ROOT="$WORK_DIR/pkg-root-i18n-ru"
I18N_SCRIPTS="$WORK_DIR/scripts-i18n-ru"
rm -rf "$I18N_ROOT" "$I18N_SCRIPTS"

PO_FILE="$PKG_SRC/po/ru/${APP_NAME}.po"
if [ ! -f "$PO_FILE" ]; then
  echo "Russian .po missing: $PO_FILE" >&2
  exit 1
fi

install -d \
  "$I18N_ROOT/usr/lib/lua/luci/i18n" \
  "$I18N_ROOT/etc/uci-defaults"

"$PO2LMO_BIN" "$PO_FILE" "$I18N_ROOT/usr/lib/lua/luci/i18n/${APP_NAME}.ru.lmo"

cat > "$I18N_ROOT/etc/uci-defaults/${I18N_NAME}" <<'EOF'
#!/bin/sh
uci -q batch <<UCI
set luci.languages.ru='Русский (Russian)'
commit luci
UCI
exit 0
EOF
chmod 0755 "$I18N_ROOT/etc/uci-defaults/${I18N_NAME}"

list_dir="$I18N_ROOT/lib/apk/packages"
mkdir -p "$list_dir"
(cd "$I18N_ROOT" && find . -type f ! -path './lib/apk/packages/*' \
   | LC_ALL=C sort | sed 's#^\./#/#') > "$list_dir/${I18N_NAME}.list"

mkdir -p "$I18N_SCRIPTS"
cat > "$I18N_SCRIPTS/post-install.sh" <<'EOF'
#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_postinst $0 $@
exit 0
EOF
chmod 0755 "$I18N_SCRIPTS"/*.sh

# ---------------------------------------------------------------------------
# Run apk mkpkg for both packages
# ---------------------------------------------------------------------------
mkpkg_app() {
  "$APK_BIN" mkpkg \
    --files "$APP_ROOT" \
    --output "$APP_OUT" \
    -I "name:$APP_NAME" \
    -I "version:$VERSION" \
    -I "description:$APP_DESC" \
    -I "arch:noarch" \
    -I "license:$PKG_LICENSE" \
    -I "origin:$APP_NAME" \
    -I "maintainer:$PKG_MAINTAINER" \
    -I "url:$PKG_URL" \
    -I "depends:$APP_DEPENDS" \
    -I "provides:${APP_NAME}-any" \
    -s "post-install:$APP_SCRIPTS/post-install.sh" \
    -s "pre-deinstall:$APP_SCRIPTS/pre-deinstall.sh" \
    -s "post-upgrade:$APP_SCRIPTS/post-upgrade.sh"
}

mkpkg_i18n() {
  "$APK_BIN" mkpkg \
    --files "$I18N_ROOT" \
    --output "$I18N_OUT" \
    -I "name:$I18N_NAME" \
    -I "version:$VERSION" \
    -I "description:$I18N_DESC" \
    -I "arch:noarch" \
    -I "license:$PKG_LICENSE" \
    -I "origin:$APP_NAME" \
    -I "maintainer:$PKG_MAINTAINER" \
    -I "url:$PKG_URL" \
    -I "depends:$I18N_DEPENDS" \
    -I "provides:${I18N_NAME}-any" \
    -s "post-install:$I18N_SCRIPTS/post-install.sh"
}

APP_OUT="$OUTPUT_DIR/${APP_NAME}_${VERSION}.apk"
I18N_OUT="$OUTPUT_DIR/${I18N_NAME}_${VERSION}.apk"
rm -f "$APP_OUT" "$I18N_OUT"

echo ">>> Building apk packages"

if [ "$(id -u)" -eq 0 ]; then
  chown -R 0:0 "$APP_ROOT" "$APP_SCRIPTS" "$I18N_ROOT" "$I18N_SCRIPTS"
  mkpkg_app
  mkpkg_i18n
elif command -v unshare >/dev/null 2>&1 && unshare -r true >/dev/null 2>&1; then
  export APP_ROOT APP_SCRIPTS APP_OUT APP_NAME APP_DESC APP_DEPENDS \
         I18N_ROOT I18N_SCRIPTS I18N_OUT I18N_NAME I18N_DESC I18N_DEPENDS \
         APK_BIN VERSION PKG_LICENSE PKG_URL PKG_MAINTAINER
  # shellcheck disable=SC2016
  unshare -r sh -c '
    chown -R 0:0 "$APP_ROOT" "$APP_SCRIPTS" "$I18N_ROOT" "$I18N_SCRIPTS"
    "$APK_BIN" mkpkg \
      --files "$APP_ROOT" --output "$APP_OUT" \
      -I "name:$APP_NAME" -I "version:$VERSION" -I "description:$APP_DESC" \
      -I "arch:noarch" -I "license:$PKG_LICENSE" -I "origin:$APP_NAME" \
      -I "maintainer:$PKG_MAINTAINER" -I "url:$PKG_URL" -I "depends:$APP_DEPENDS" \
      -I "provides:${APP_NAME}-any" \
      -s "post-install:$APP_SCRIPTS/post-install.sh" \
      -s "pre-deinstall:$APP_SCRIPTS/pre-deinstall.sh" \
      -s "post-upgrade:$APP_SCRIPTS/post-upgrade.sh"
    "$APK_BIN" mkpkg \
      --files "$I18N_ROOT" --output "$I18N_OUT" \
      -I "name:$I18N_NAME" -I "version:$VERSION" -I "description:$I18N_DESC" \
      -I "arch:noarch" -I "license:$PKG_LICENSE" -I "origin:$APP_NAME" \
      -I "maintainer:$PKG_MAINTAINER" -I "url:$PKG_URL" -I "depends:$I18N_DEPENDS" \
      -I "provides:${I18N_NAME}-any" \
      -s "post-install:$I18N_SCRIPTS/post-install.sh"
  '
else
  export APP_ROOT APP_SCRIPTS APP_OUT APP_NAME APP_DESC APP_DEPENDS \
         I18N_ROOT I18N_SCRIPTS I18N_OUT I18N_NAME I18N_DESC I18N_DEPENDS \
         APK_BIN VERSION PKG_LICENSE PKG_URL PKG_MAINTAINER
  # shellcheck disable=SC2016
  fakeroot sh -c '
    chown -R 0:0 "$APP_ROOT" "$APP_SCRIPTS" "$I18N_ROOT" "$I18N_SCRIPTS"
    "$APK_BIN" mkpkg \
      --files "$APP_ROOT" --output "$APP_OUT" \
      -I "name:$APP_NAME" -I "version:$VERSION" -I "description:$APP_DESC" \
      -I "arch:noarch" -I "license:$PKG_LICENSE" -I "origin:$APP_NAME" \
      -I "maintainer:$PKG_MAINTAINER" -I "url:$PKG_URL" -I "depends:$APP_DEPENDS" \
      -I "provides:${APP_NAME}-any" \
      -s "post-install:$APP_SCRIPTS/post-install.sh" \
      -s "pre-deinstall:$APP_SCRIPTS/pre-deinstall.sh" \
      -s "post-upgrade:$APP_SCRIPTS/post-upgrade.sh"
    "$APK_BIN" mkpkg \
      --files "$I18N_ROOT" --output "$I18N_OUT" \
      -I "name:$I18N_NAME" -I "version:$VERSION" -I "description:$I18N_DESC" \
      -I "arch:noarch" -I "license:$PKG_LICENSE" -I "origin:$APP_NAME" \
      -I "maintainer:$PKG_MAINTAINER" -I "url:$PKG_URL" -I "depends:$I18N_DEPENDS" \
      -I "provides:${I18N_NAME}-any" \
      -s "post-install:$I18N_SCRIPTS/post-install.sh"
  '
fi

echo ">>> Verifying package metadata"
for out in "$APP_OUT" "$I18N_OUT"; do
  echo "--- $(basename "$out")"
  "$APK_BIN" adbdump "$out" | grep -E "^  (name|version|arch): " || true
done

echo ">>> Built:"
echo "    $APP_OUT"
echo "    $I18N_OUT"
