#!/bin/sh
# tests/browser/run-vm-lane.sh — narrow qemu-VM browser lane: the NET_ADMIN/
# tproxy save-roundtrip the light container cannot do. Seeds a tproxy inbound that
# requests nft_rules, drives the real generate+restart through ubus, then asserts
# `nft list ruleset` installed the inet singbox_ui table. VM-only.
#
# CI hookup: a `browser-vm-lane` step under the `ui` domain (owned by Phase 1)
# invokes this inside the qemu VM (via tests/run-vm.sh, SINGBOX_TESTS_IN_VM=1)
# BEFORE the 90-vm-tproxy-roundtrip.mjs carrier reads /tmp/singbox-ui/.vm_lane_nft.
# Outside the VM it SKIPs cleanly (no NET_ADMIN/nft).
set -eu
. "$(dirname "$0")/../lib/sb_helpers.sh"
cd "$(dirname "$0")/../.."

if [ "${SINGBOX_TESTS_IN_VM:-0}" != "1" ]; then
    echo "SKIP run-vm-lane: tproxy/NET_ADMIN roundtrip runs only inside the qemu VM"
    exit 0
fi

SID=_vmlane_tproxy
uci -q delete singbox-ui.$SID 2>/dev/null || true
uci set singbox-ui.$SID=inbound
uci set singbox-ui.$SID.protocol=tproxy
uci set singbox-ui.$SID.enabled=1
uci set singbox-ui.$SID.listen='::'
uci set singbox-ui.$SID.listen_port=7899
uci add_list singbox-ui.$SID.interface=br-lan
uci set singbox-ui.$SID.nft_rules=1
uci commit singbox-ui

ubus call singbox-ui generate >/dev/null 2>&1 || { echo "FAIL: generate"; exit 1; }
ubus call singbox-ui restart  >/dev/null 2>&1 || true

# Poll for the nft table (apply is async); record the result for the .mjs carrier.
mkdir -p /tmp/singbox-ui
i=0
while [ $i -lt 15 ]; do
    if nft list ruleset 2>/dev/null | grep -q 'table inet singbox_ui'; then break; fi
    i=$((i+1)); sleep 1
done
nft list ruleset 2>/dev/null | grep 'table inet singbox_ui' > /tmp/singbox-ui/.vm_lane_nft || true

uci -q delete singbox-ui.$SID; uci commit singbox-ui
ubus call singbox-ui generate >/dev/null 2>&1 || true
ubus call singbox-ui restart  >/dev/null 2>&1 || true

if grep -q 'singbox_ui' /tmp/singbox-ui/.vm_lane_nft; then
    echo "PASS: run-vm-lane installed inet singbox_ui nft table"
else
    echo "FAIL: inet singbox_ui nft table not installed after tproxy save-roundtrip"
    exit 1
fi
