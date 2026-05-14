#!/bin/sh
# tests/test_nftables_emit.sh
set -e

SCRIPT=luci-app-singbox-ui/root/etc/singbox-ui/nftables.sh

if [ ! -x "$SCRIPT" ]; then
  echo "FAIL: $SCRIPT not present or not executable"
  exit 1
fi

echo "-- shellcheck"
shellcheck -s sh "$SCRIPT"

echo "-- emit produces two chains with correct priorities"
out=$("$SCRIPT" emit 7893 "198.18.0.0/15" "fc00::/18" "br-lan")
echo "$out" | grep -q "table inet singbox_ui"     || { echo "FAIL: missing table"; exit 1; }
echo "$out" | grep -q "chain prerouting_mark"     || { echo "FAIL: missing prerouting_mark chain"; exit 1; }
echo "$out" | grep -q "chain prerouting_tproxy"   || { echo "FAIL: missing prerouting_tproxy chain"; exit 1; }
echo "$out" | grep -q "priority -150"             || { echo "FAIL: missing priority -150 (mangle)"; exit 1; }
echo "$out" | grep -q "priority -149"             || { echo "FAIL: missing priority -149 (mangle+1)"; exit 1; }

echo "-- mark chain: iifname + ip/ip6 match + mark set (no tproxy)"
mark_section=$(echo "$out" | awk '/chain prerouting_mark/,/^[[:space:]]*}/')
echo "$mark_section" | grep -q 'iifname "br-lan"'              || { echo "FAIL: missing iifname in mark chain"; exit 1; }
echo "$mark_section" | grep -q "198.18.0.0/15"                 || { echo "FAIL: missing v4 range in mark chain"; exit 1; }
echo "$mark_section" | grep -q "fc00::/18"                     || { echo "FAIL: missing v6 range in mark chain"; exit 1; }
echo "$mark_section" | grep -q "meta mark set 0x1"             || { echo "FAIL: missing mark set in mark chain"; exit 1; }
echo "$mark_section" | grep -q "tproxy"                        && { echo "FAIL: tproxy must not appear in mark chain"; exit 1; }

echo "-- tproxy chain: mark check + tproxy targets (no iifname)"
tproxy_section=$(echo "$out" | awk '/chain prerouting_tproxy/,/^[[:space:]]*}/')
echo "$tproxy_section" | grep -q "meta mark 0x1"               || { echo "FAIL: missing mark match in tproxy chain"; exit 1; }
echo "$tproxy_section" | grep -q "127.0.0.1:7893"             || { echo "FAIL: missing v4 tproxy target"; exit 1; }
echo "$tproxy_section" | grep -q "\[::1\]:7893"               || { echo "FAIL: missing v6 tproxy target"; exit 1; }
echo "$tproxy_section" | grep -q "iifname"                     && { echo "FAIL: iifname must not appear in tproxy chain"; exit 1; }

echo "-- nft -c accepts the emitted rules"
tmp=$(mktemp)
"$SCRIPT" emit 7893 "198.18.0.0/15" "fc00::/18" "br-lan" > "$tmp"
if ! nft -c -f "$tmp" 2>nft.err; then
  if grep -qiE "tproxy|cache initialization failed|operation not permitted|permission denied" nft.err; then
    echo "SKIP: nft -c unavailable in this environment ($(head -n1 nft.err))"
  else
    echo "FAIL: nft rejected emitted rules:"
    cat nft.err
    exit 1
  fi
fi
rm -f "$tmp" nft.err

echo "-- emit with custom port and interface"
out=$("$SCRIPT" emit 1234 "10.0.0.0/8" "" "eth0")
echo "$out" | grep -q "127.0.0.1:1234"    || { echo "FAIL: wrong port"; exit 1; }
echo "$out" | grep -q 'iifname "eth0"'    || { echo "FAIL: wrong interface"; exit 1; }
echo "$out" | grep -q "ip6 daddr"         && { echo "FAIL: ip6 rule emitted for empty v6"; exit 1; }

echo "-- empty rs_*.json cache: output is phase-2-equivalent"
rm -f /tmp/singbox-ui/rs_*.json 2>/dev/null
out=$("$SCRIPT" emit 7893 "198.18.0.0/15" "fc00::/18" "br-lan")
echo "$out" | grep -q "table inet singbox_ui"  || { echo "FAIL: missing table"; exit 1; }
echo "$out" | grep -q "chain prerouting_mark"  || { echo "FAIL: missing mark chain"; exit 1; }
echo "$out" | grep -q "set rs_"                && { echo "FAIL: unexpected nfset emitted with empty cache"; exit 1; }
echo "$out" | grep -q "@rs_"                   && { echo "FAIL: unexpected nfset rule emitted"; exit 1; }

echo "OK"
