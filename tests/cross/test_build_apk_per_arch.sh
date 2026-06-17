#!/bin/sh
# Asserts scripts/build-apk.sh produces the FOUR-package split:
#   - bbolt-client_<ver>_<arch>.apk   one per covered OpenWrt arch (20 total),
#     each carrying the native binary at usr/libexec/singbox-ui/bbolt-client.
#   - singbox-ui_<ver>.apk            noarch backend.
#   - luci-app-singbox-ui_<ver>.apk   noarch LuCI frontend.
#   - luci-i18n-singbox-ui-ru_<ver>.apk  noarch Russian translation.
#
# Driven via APK_MKPKG_STUB=1, so apk mkpkg is a touch-stub (no SDK needed) and
# the .apk outputs are empty placeholders — we assert by NAME and COUNT, and we
# verify the bbolt binary is laid down under the BBOLT-CLIENT package root (NOT
# the noarch backend root), proving the binary belongs to bbolt-client.
set -eu
# build-apk.sh is a host build script (#!/usr/bin/env bash) and uses bash-only
# features. The OpenWrt qemu guest has no bash, so this test SKIPs there (it runs
# for real in the bash-equipped CI lint job and on dev hosts). See tests/run.sh.
command -v bash >/dev/null 2>&1 || { echo "SKIP test_build_apk_per_arch: bash not available (build-apk.sh needs bash)"; exit 0; }
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
BIN="$WORK/bins"; mkdir -p "$BIN"
for a in x86_64 aarch64 armv7 mipsel mips; do
  printf 'BBOLT-%s\n' "$a" > "$BIN/bbolt-client-rs-$a"
done
OUT="$WORK/dist"
APK_MKPKG_STUB=1 BBOLT_BIN_DIR="$BIN" WORK_DIR="$WORK/.build" \
  bash "$ROOT/scripts/build-apk.sh" 0.0.0-r1 "$OUT" >/dev/null 2>"$WORK/err" || {
    echo "build-apk.sh failed:"; cat "$WORK/err"; exit 1; }

# --- per-arch bbolt-client: exactly 20 (one per arch in the map) ---
bbolt=$(find "$OUT" -maxdepth 1 -name 'bbolt-client_0.0.0-r1_*.apk' 2>/dev/null | wc -l | tr -d ' ')
[ "$bbolt" = "20" ] || { echo "expected 20 per-arch bbolt-client apks, got $bbolt"; ls "$OUT"; exit 1; }

# --- the three noarch packages: exactly one each ---
for name in singbox-ui luci-app-singbox-ui luci-i18n-singbox-ui-ru; do
  n=$(find "$OUT" -maxdepth 1 -name "${name}_0.0.0-r1.apk" 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" = "1" ] || { echo "expected exactly 1 ${name} apk, got $n"; ls "$OUT"; exit 1; }
done

# --- total apk count is exactly 23 (20 bbolt + 3 noarch) ---
total=$(find "$OUT" -maxdepth 1 -name '*.apk' 2>/dev/null | wc -l | tr -d ' ')
[ "$total" = "23" ] || { echo "expected 23 apks total (20 bbolt + 3 noarch), got $total"; ls "$OUT"; exit 1; }

# --- the bbolt binary belongs to the bbolt-client package, NOT the backend ---
# build-apk lays each per-arch bbolt-client root at pkg-root-bbolt-<exact-arch>;
# the embedded binary is the correct per-ABI build for that arch.
for probe in 'aarch64_cortex-a53:aarch64' 'mipsel_24kc:mipsel' 'x86_64:x86_64'; do
  arch="${probe%%:*}"; abi="${probe##*:}"
  root="$WORK/.build/pkg-root-bbolt-$arch"
  [ -f "$root/usr/libexec/singbox-ui/bbolt-client" ] \
    || { echo "bbolt-client pkg root for $arch missing the binary"; exit 1; }
  grep -q "BBOLT-$abi" "$root/usr/libexec/singbox-ui/bbolt-client" \
    || { echo "bbolt-client pkg for $arch embeds the wrong ABI binary (want $abi)"; exit 1; }
done

# --- the noarch backend root must NOT carry the bbolt binary (it's a separate
#     package now; the backend only DEPENDS on bbolt-client) ---
if [ -e "$WORK/.build/pkg-root-singbox-ui/usr/libexec/singbox-ui/bbolt-client" ]; then
  echo "singbox-ui (backend) root must NOT embed bbolt-client — it's a separate package"; exit 1
fi

echo "PASS"
