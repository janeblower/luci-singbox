#!/bin/sh
# tests/cross/test_i18n_package.sh
# i18n-package integration (goal d). Asserts the Russian translation package is
# built correctly by scripts/build-apk.sh:
#   1. the .po source basename is the UN-renamed i18n domain `luci-singbox-ui`
#      (the package is luci-app-singbox-ui, but the .po/.lmo/domain stay
#      luci-singbox-ui — renaming silently breaks translations);
#   2. build-apk lays the .lmo into the i18n package root at
#      usr/lib/lua/luci/i18n/luci-singbox-ui.ru.lmo;
#   3. the produced luci-i18n-singbox-ui-ru .apk DEPENDS luci-app-singbox-ui;
#   4. when a real SDK apk + po2lmo exist, the .lmo is a non-empty compiled file.
#
# Runs via build-apk.sh's own APK_MKPKG_STUB=1 seam (no SDK/network needed for
# the naming/DEPENDS contract); the po2lmo content check is gated on a real apk.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
fail() { echo "FAIL: $1" >&2; exit 1; }

PO="$ROOT/luci-app-singbox-ui/po/ru/luci-singbox-ui.po"
DOMAIN="luci-singbox-ui"
I18N_NAME="luci-i18n-singbox-ui-ru"

# (1) .po source carries the un-renamed domain basename.
[ -f "$PO" ] || fail "Russian .po missing at $PO (domain '$DOMAIN' must NOT be renamed)"

# Build the noarch packages with the stub seam: no SDK download, no po2lmo, but
# the package roots + apk metadata are fully assembled. SINGBOX_SKIP_BBOLT=1 is
# implied by the stub for the bbolt step; we only care about the i18n package.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
( cd "$ROOT" && APK_MKPKG_STUB=1 WORK_DIR="$TMP/build" \
    bash scripts/build-apk.sh 0.0.0-r1 "$TMP/dist" >/dev/null ) \
  || fail "build-apk.sh (stub) failed"

# (2) the .lmo lands in the i18n package root under the un-renamed domain name.
LMO="$TMP/build/pkg-root-i18n-ru/usr/lib/lua/luci/i18n/${DOMAIN}.ru.lmo"
[ -f "$LMO" ] || fail "i18n .lmo not laid into package root at $LMO (basename must stay '$DOMAIN')"

# The package's own file list must reference that .lmo path.
LIST="$TMP/build/pkg-root-i18n-ru/lib/apk/packages/${I18N_NAME}.list"
[ -f "$LIST" ] || fail "i18n package .list missing at $LIST"
grep -q "/usr/lib/lua/luci/i18n/${DOMAIN}.ru.lmo" "$LIST" \
  || fail ".lmo not enumerated in i18n .list (domain basename drift?)"

# (3) DEPENDS luci-app-singbox-ui — read from the produced apk if a real apk is
# available, else from the stub package root is impossible (stub apk is empty),
# so assert against build-apk.sh's I18N_DEPENDS constant directly as the contract.
# shellcheck disable=SC2016  # grep a literal '$LUCIAPP_NAME' substring in build-apk.sh, no expansion intended
grep -Eq '^I18N_DEPENDS="libc \$LUCIAPP_NAME"$' "$ROOT/scripts/build-apk.sh" \
  || fail "build-apk.sh I18N_DEPENDS no longer 'libc \$LUCIAPP_NAME' (must DEPEND luci-app-singbox-ui)"
grep -Eq '^LUCIAPP_NAME="luci-app-singbox-ui"$' "$ROOT/scripts/build-apk.sh" \
  || fail "build-apk.sh LUCIAPP_NAME changed; i18n DEPENDS target drifted"

# (4) Real po2lmo content check — only when a capable SDK apk exists. The stub
# touches an empty .lmo; a real build must compile a non-empty one and the apk
# must declare depends: luci-app-singbox-ui.
APK="${SINGBOX_APK_BIN:-}"
[ -z "$APK" ] && [ -x "$ROOT/.build/sdk/staging_dir/host/bin/apk" ] && APK="$ROOT/.build/sdk/staging_dir/host/bin/apk"
PO2LMO=""
[ -x "$ROOT/.build/sdk/staging_dir/hostpkg/bin/po2lmo" ] && PO2LMO="$ROOT/.build/sdk/staging_dir/hostpkg/bin/po2lmo"
if [ -n "$APK" ] && "$APK" --version 2>/dev/null | grep -q "apk-tools 3" && [ -n "$PO2LMO" ]; then
  REALOUT="$TMP/realdist"
  ( cd "$ROOT" && SINGBOX_SKIP_BBOLT=1 WORK_DIR="$TMP/realbuild" \
      bash scripts/build-apk.sh 0.0.0-r1 "$REALOUT" >/dev/null ) \
    || fail "build-apk.sh (real, skip-bbolt) failed"
  REALLMO="$TMP/realbuild/pkg-root-i18n-ru/usr/lib/lua/luci/i18n/${DOMAIN}.ru.lmo"
  [ -s "$REALLMO" ] || fail "po2lmo produced an empty .lmo at $REALLMO"
  APKFILE="$REALOUT/${I18N_NAME}_0.0.0-r1.apk"
  [ -f "$APKFILE" ] || fail "i18n apk not produced at $APKFILE"
  "$APK" adbdump "$APKFILE" 2>/dev/null | grep -A20 -i 'depends' \
    | grep -q 'luci-app-singbox-ui' \
    || fail "produced i18n apk does not DEPEND luci-app-singbox-ui"
else
  echo "note: real po2lmo content check skipped (no SDK apk+po2lmo); naming+DEPENDS contract still verified"
fi

echo "PASS test_i18n_package"
