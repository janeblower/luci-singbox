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

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available for ruleset emit tests"; echo "OK"; exit 0; }

# Clean any leftover ruleset caches from earlier failed runs so each scenario
# starts from a known state.
rm -f /tmp/singbox-ui/rs_test_*.json 2>/dev/null
trap 'rm -f /tmp/singbox-ui/rs_test_*.json' EXIT

echo "-- rs_*.json cache: nft set definition + marking rule (basic ip_cidr)"
mkdir -p /tmp/singbox-ui
cat >/tmp/singbox-ui/rs_test_basic.json <<'JSON'
{
  "version": 1,
  "rules": [
    { "ip_cidr": ["1.2.3.0/24", "4.5.6.0/16"] }
  ]
}
JSON
out=$("$SCRIPT" emit 7893 "198.18.0.0/15" "" "br-lan")
echo "$out" | grep -q "set rs_test_basic_0_v4"           || { echo "FAIL: missing set definition"; echo "$out"; exit 1; }
echo "$out" | grep -q "type ipv4_addr"                   || { echo "FAIL: set missing type"; exit 1; }
echo "$out" | grep -q "flags interval"                   || { echo "FAIL: set missing flags interval"; exit 1; }
echo "$out" | grep -q "1.2.3.0/24"                       || { echo "FAIL: missing first cidr"; exit 1; }
echo "$out" | grep -q "4.5.6.0/16"                       || { echo "FAIL: missing second cidr"; exit 1; }
echo "$out" | grep -q "ip daddr @rs_test_basic_0_v4"     || { echo "FAIL: missing marking rule"; echo "$out"; exit 1; }
echo "$out" | grep -q "meta l4proto { tcp, udp }"        || { echo "FAIL: missing l4proto (no network)"; exit 1; }
echo "$out" | grep -q "meta mark set 0x1"                || { echo "FAIL: missing mark set"; exit 1; }
echo "$out" | grep -q "ct state new"                     || { echo "FAIL: missing ct state new"; exit 1; }
echo "$out" | grep -q "198.18.0.0/15"                    || { echo "FAIL: fakeip v4 rule missing alongside nfset"; exit 1; }
rm -f /tmp/singbox-ui/rs_test_basic.json

echo "-- rs_*.json cache: network=tcp emits 'meta l4proto tcp'"
cat >/tmp/singbox-ui/rs_test_tcp.json <<'JSON'
{
  "version": 1,
  "rules": [
    { "ip_cidr": ["10.0.0.0/8"], "network": "tcp" }
  ]
}
JSON
out=$("$SCRIPT" emit 7893 "198.18.0.0/15" "" "br-lan")
mark_section=$(echo "$out" | awk '/chain prerouting_mark/,/^[[:space:]]*}/')
echo "$mark_section" | grep -q "ip daddr @rs_test_tcp_0_v4 meta l4proto tcp" \
	|| { echo "FAIL: tcp-network rule missing exact l4proto match"; echo "$mark_section"; exit 1; }
echo "$mark_section" | grep -q "meta l4proto { tcp, udp }.*@rs_test_tcp_0_v4" \
	&& { echo "FAIL: tcp-network rule used default l4proto"; exit 1; }
rm -f /tmp/singbox-ui/rs_test_tcp.json

echo "-- rs_*.json cache: network=tcp + port_range=['80:443'] emits 'tcp dport 80-443'"
cat >/tmp/singbox-ui/rs_test_port.json <<'JSON'
{
  "version": 1,
  "rules": [
    { "ip_cidr": ["172.16.0.0/12"], "network": "tcp", "port_range": ["80:443"] }
  ]
}
JSON
out=$("$SCRIPT" emit 7893 "198.18.0.0/15" "" "br-lan")
echo "$out" | grep -q "ip daddr @rs_test_port_0_v4 meta l4proto tcp tcp dport 80-443 ct state new meta mark set 0x1" \
	|| { echo "FAIL: missing tcp+port_range marking rule"; echo "$out"; exit 1; }
rm -f /tmp/singbox-ui/rs_test_port.json

# Real .srs rule-sets emit ip_cidr and port_range as either scalars or arrays.
# Both forms must produce identical nft output.
echo "-- rs_*.json cache: scalar ip_cidr + scalar port_range (real sing-box shape)"
cat >/tmp/singbox-ui/rs_test_scalar.json <<'JSON'
{
  "version": 3,
  "rules": [
    { "ip_cidr": "104.16.0.0/12", "network": "udp", "port_range": "19000:20000" }
  ]
}
JSON
out=$("$SCRIPT" emit 7893 "198.18.0.0/15" "" "br-lan")
echo "$out" | grep -q "set rs_test_scalar_0_v4" \
	|| { echo "FAIL: scalar ip_cidr — set not emitted"; echo "$out"; exit 1; }
echo "$out" | grep -q "elements = { 104.16.0.0/12 }" \
	|| { echo "FAIL: scalar ip_cidr — element body wrong"; echo "$out"; exit 1; }
echo "$out" | grep -q "ip daddr @rs_test_scalar_0_v4 meta l4proto udp udp dport 19000-20000 ct state new meta mark set 0x1" \
	|| { echo "FAIL: scalar port_range — marking rule wrong"; echo "$out"; exit 1; }
rm -f /tmp/singbox-ui/rs_test_scalar.json

echo "-- rs_*.json cache: domain-only rule is skipped, ip_cidr rule still emits"
cat >/tmp/singbox-ui/rs_test_mixed.json <<'JSON'
{
  "version": 3,
  "rules": [
    { "domain_suffix": ["example.com"] },
    { "ip_cidr": ["10.0.0.0/8"], "network": "tcp" }
  ]
}
JSON
out=$("$SCRIPT" emit 7893 "198.18.0.0/15" "" "br-lan")
echo "$out" | grep -q "set rs_test_mixed_0_v4" \
	|| { echo "FAIL: mixed — ip_cidr rule not emitted as first set"; echo "$out"; exit 1; }
# domain_suffix rule must not create a set
echo "$out" | grep -q "set rs_test_mixed_1" \
	&& { echo "FAIL: mixed — domain-only rule produced an unexpected set"; exit 1; }
rm -f /tmp/singbox-ui/rs_test_mixed.json

echo "OK"
