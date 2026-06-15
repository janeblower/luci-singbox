#!/bin/sh
# Guards Bug 3: nftables must not be an explicit package dependency (it ships in
# OpenWrt base / fw4); curl must remain (subscription fetch uses it).
set -eu
MK="luci-singbox-ui/Makefile"
line="$(grep '^LUCI_DEPENDS' "$MK")"
echo "$line" | grep -q '+curl'      || { echo "FAIL: +curl dependency missing"; exit 1; }
echo "$line" | grep -q '+nftables'  && { echo "FAIL: +nftables should be removed"; exit 1; } || true

# The shipped .apk declares its own deps in build-apk.sh — same invariant.
apkline="$(grep '^APP_DEPENDS=' scripts/build-apk.sh)"
echo "$apkline" | grep -q 'curl'      || { echo "FAIL: build-apk.sh APP_DEPENDS missing curl"; exit 1; }
echo "$apkline" | grep -q 'nftables'  && { echo "FAIL: build-apk.sh APP_DEPENDS still has nftables"; exit 1; } || true

echo "PASS"
