#!/bin/sh
# Guards Bug 3: nftables must not be an explicit package dependency (it ships in
# OpenWrt base / fw4); curl must remain (subscription fetch uses it).
set -eu
MK="luci-singbox-ui/Makefile"
line="$(grep '^LUCI_DEPENDS' "$MK")"
echo "$line" | grep -q '+curl'      || { echo "FAIL: +curl dependency missing"; exit 1; }
echo "$line" | grep -q '+nftables'  && { echo "FAIL: +nftables should be removed"; exit 1; } || true
echo "PASS"
