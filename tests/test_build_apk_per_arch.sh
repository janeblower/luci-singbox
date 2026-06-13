#!/bin/sh
# Asserts build-apk.sh produces one main apk per covered OpenWrt arch, each
# embedding the correct bbolt binary, plus exactly one noarch i18n apk.
set -eu
# build-apk.sh is a host build script (#!/usr/bin/env bash) and uses bash-only
# features. The OpenWrt qemu guest has no bash, so this test SKIPs there (it runs
# for real in the bash-equipped CI lint job and on dev hosts). See tests/run.sh.
command -v bash >/dev/null 2>&1 || { echo "SKIP test_build_apk_per_arch: bash not available (build-apk.sh needs bash)"; exit 0; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
BIN="$WORK/bins"; mkdir -p "$BIN"
for a in x86_64 aarch64 armv7 mipsel mips; do
  printf 'BBOLT-%s\n' "$a" > "$BIN/bbolt-client-rs-$a"
done
OUT="$WORK/dist"
APK_MKPKG_STUB=1 BBOLT_BIN_DIR="$BIN" WORK_DIR="$WORK/.build" \
  bash "$ROOT/scripts/build-apk.sh" 0.0.0-r1 "$OUT" >/dev/null 2>"$WORK/err" || {
    echo "build-apk.sh failed:"; cat "$WORK/err"; exit 1; }
mains=$(find "$OUT" -maxdepth 1 -name 'luci-singbox-ui_0.0.0-r1_*.apk' 2>/dev/null | wc -l | tr -d ' ')
[ "$mains" = "20" ] || { echo "expected 20 per-arch main apks, got $mains"; ls "$OUT"; exit 1; }
i18n=$(find "$OUT" -maxdepth 1 -name 'luci-i18n-singbox-ui-ru_0.0.0-r1.apk' 2>/dev/null | wc -l | tr -d ' ')
[ "$i18n" = "1" ] || { echo "expected 1 i18n apk"; exit 1; }
root="$WORK/.build/pkg-root-app-aarch64_cortex-a53"
grep -q "BBOLT-aarch64" "$root/usr/libexec/singbox-ui/bbolt-client" \
  || { echo "aarch64_cortex-a53 pkg missing aarch64 bbolt binary"; exit 1; }
root="$WORK/.build/pkg-root-app-mipsel_24kc"
grep -q "BBOLT-mipsel" "$root/usr/libexec/singbox-ui/bbolt-client" \
  || { echo "mipsel_24kc pkg missing mipsel binary"; exit 1; }
grep -q "BBOLT-x86_64" "$WORK/.build/pkg-root-app-x86_64/usr/libexec/singbox-ui/bbolt-client" \
  || { echo "x86_64 pkg missing x86_64 binary"; exit 1; }
echo "PASS"
