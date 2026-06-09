#!/bin/sh
# tests/test_nftables_emit.sh
set -e

SCRIPT=luci-app-singbox-ui/root/usr/share/singbox-ui/nftables.uc

if [ ! -x "$SCRIPT" ]; then
  echo "FAIL: $SCRIPT not present or not executable"
  exit 1
fi

# ucode is required to drive .uc. Skip cleanly when missing (mirrors
# test_generate.sh / test_nftables_uc.sh).
if command -v ucode >/dev/null 2>&1; then
	UCODE_BIN=ucode
	UCODE_LIB_FLAGS="-L ${UCODE_APP_LIB_DIR:-$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/lib}"
elif [ -x "${UCODE_BIN:-}" ] && [ -d "${UCODE_STUB_DIR:-}" ]; then
	UCODE_LIB_FLAGS="-L $UCODE_STUB_DIR"
	[ -n "${UCODE_LIB_DIR:-}" ] && UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L $UCODE_LIB_DIR"
	UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L ${UCODE_APP_LIB_DIR:-$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/lib}"
else
	echo "SKIP: ucode not available"
	exit 0
fi

echo "-- ucode parse check"
# `-p EXPR` evaluates EXPR; use `-c -o /dev/null FILE` for a compile-only check.
"$UCODE_BIN" -c -o /dev/null "$SCRIPT"

echo "-- emit: single prerouting chain at priority mangle"
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" emit 7895 198.18.0.0/15 fc00::/18 br-lan)
echo "$out" | grep -q 'chain prerouting {' || { echo FAIL prerouting; exit 1; }
echo "$out" | grep -q 'type filter hook prerouting priority mangle' || { echo FAIL prio; exit 1; }
echo "$out" | grep -q 'chain prerouting_mark' && { echo "FAIL: old chain still present"; exit 1; }
echo "$out" | grep -q 'chain prerouting_tproxy' && { echo "FAIL: old chain still present"; exit 1; }
:

echo "-- emit: named sets wan_ifaces, fakeip4, fakeip6"
echo "$out" | grep -q 'set wan_ifaces' || { echo FAIL wan_ifaces; exit 1; }
echo "$out" | grep -q 'type ifname' || { echo FAIL ifname; exit 1; }
echo "$out" | grep -q 'set fakeip4' || { echo FAIL fakeip4 set; exit 1; }
echo "$out" | grep -q 'set fakeip6' || { echo FAIL fakeip6 set; exit 1; }

echo "-- emit: socket transparent fast-path is the first rule in prerouting"
echo "$out" | awk '/chain prerouting \{/{flag=1; next} flag && /^\t\t[a-zA-Z]/ && !/^\t\ttype/{print; exit}' \
	| grep -q 'socket transparent 1' || { echo FAIL fast-path; exit 1; }

echo "-- emit: rs_* and fakeip decision rules write ct mark, not meta mark"
echo "$out" | grep 'ct state new' | grep -q 'meta mark set' && { echo "FAIL: decision uses meta mark"; exit 1; }
echo "$out" | grep -q 'ct mark set ct mark or 0x1' || { echo "FAIL: no ct mark set"; exit 1; }
:

echo "-- emit: TPROXY uses AND-mask (not exact equality)"
echo "$out" | grep -q 'meta mark and 0x1 == 0x1' || { echo "FAIL: not AND-mask"; exit 1; }
echo "$out" | grep 'tproxy' | grep -q '^.*meta mark 0x1 meta l4proto' && { echo "FAIL: exact equality still present"; exit 1; }
:

echo "-- emit: tproxy targets present for tcp+udp, v4+v6, on the configured port (whitespace-agnostic)"
norm=$(echo "$out" | tr -s ' ')
echo "$norm" | grep -q 'tproxy ip to 127.0.0.1:7895'  || { echo FAIL v4; echo "$norm" | grep tproxy; exit 1; }
echo "$norm" | grep -q 'tproxy ip6 to \[::1\]:7895'   || { echo FAIL v6; echo "$norm" | grep tproxy; exit 1; }
# Still exactly four tproxy rules (tcp+udp × v4+v6); count is semantic, not cosmetic.
n=$(echo "$out" | grep -c 'tproxy ip')
[ "$n" -eq 4 ] || { echo "FAIL: expected 4 tproxy rules, got $n"; exit 1; }

echo "-- nft -c accepts the emitted rules"
tmp=$(mktemp)
# shellcheck disable=SC2086
"$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" emit 7893 "198.18.0.0/15" "fc00::/18" "br-lan" > "$tmp"
if ! nft -c -f "$tmp" 2>nft.err; then
  if grep -qiE "tproxy|socket|cache initialization failed|operation not permitted|permission denied" nft.err; then
    echo "SKIP: nft -c unavailable in this environment ($(head -n1 nft.err))"
  else
    echo "FAIL: nft rejected emitted rules:"
    cat nft.err
    exit 1
  fi
fi
rm -f "$tmp" nft.err

echo "-- emit with custom port and interface"
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" emit 1234 "10.0.0.0/8" "" "eth0")
echo "$out" | grep -q "127.0.0.1:1234"    || { echo "FAIL: wrong port"; exit 1; }
echo "$out" | grep -q '"eth0"'             || { echo "FAIL: wrong interface"; exit 1; }
echo "$out" | grep -q "ip6 daddr"         && { echo "FAIL: ip6 rule emitted for empty v6"; exit 1; }

echo "-- empty rs_*.json cache: output is phase-2-equivalent"
rm -f /tmp/singbox-ui/rs_*.json 2>/dev/null
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" emit 7893 "198.18.0.0/15" "fc00::/18" "br-lan")
echo "$out" | grep -q "table inet singbox_ui"  || { echo "FAIL: missing table"; exit 1; }
echo "$out" | grep -q "chain prerouting {"     || { echo "FAIL: missing prerouting chain"; exit 1; }
echo "$out" | grep -q "set rs_"                && { echo "FAIL: unexpected nfset emitted with empty cache"; exit 1; }
echo "$out" | grep -q "@rs_"                   && { echo "FAIL: unexpected nfset rule emitted"; exit 1; }

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
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" emit 7893 "198.18.0.0/15" "" "br-lan")
echo "$out" | grep -q "set rs_test_basic_0_v4"           || { echo "FAIL: missing set definition"; echo "$out"; exit 1; }
echo "$out" | grep -q "type ipv4_addr"                   || { echo "FAIL: set missing type"; exit 1; }
echo "$out" | grep -q "flags interval"                   || { echo "FAIL: set missing flags interval"; exit 1; }
echo "$out" | grep -q "1.2.3.0/24"                       || { echo "FAIL: missing first cidr"; exit 1; }
echo "$out" | grep -q "4.5.6.0/16"                       || { echo "FAIL: missing second cidr"; exit 1; }
echo "$out" | grep -q "ip daddr @rs_test_basic_0_v4"     || { echo "FAIL: missing marking rule"; echo "$out"; exit 1; }
echo "$out" | grep -q "meta l4proto { tcp, udp }"        || { echo "FAIL: missing l4proto (no network)"; exit 1; }
echo "$out" | grep -q "ct mark set ct mark or 0x1"       || { echo "FAIL: missing ct mark set"; exit 1; }
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
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" emit 7893 "198.18.0.0/15" "" "br-lan")
echo "$out" | grep -q "ip daddr @rs_test_tcp_0_v4 meta l4proto tcp" \
	|| { echo "FAIL: tcp-network rule missing exact l4proto match"; echo "$out"; exit 1; }
echo "$out" | grep "ip daddr @rs_test_tcp_0_v4" | grep -q "meta l4proto { tcp, udp }" \
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
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" emit 7893 "198.18.0.0/15" "" "br-lan")
echo "$out" | grep -q "ip daddr @rs_test_port_0_v4 meta l4proto tcp tcp dport 80-443 ct state new ct mark set ct mark or 0x1" \
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
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" emit 7893 "198.18.0.0/15" "" "br-lan")
echo "$out" | grep -q "set rs_test_scalar_0_v4" \
	|| { echo "FAIL: scalar ip_cidr — set not emitted"; echo "$out"; exit 1; }
echo "$out" | grep -Eq "elements = \{ 104\.16\.0\.0/12 \}" \
	|| { echo "FAIL: scalar ip_cidr — element body wrong"; echo "$out"; exit 1; }
echo "$out" | grep -q "ip daddr @rs_test_scalar_0_v4 meta l4proto udp udp dport 19000-20000 ct state new ct mark set ct mark or 0x1" \
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
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" emit 7893 "198.18.0.0/15" "" "br-lan")
# rule idx mirrors source position (incl. skipped domain-only), so the
# ip_cidr rule at array index 1 produces rs_..._1_v4, not _0_.
echo "$out" | grep -q "set rs_test_mixed_1_v4" \
	|| { echo "FAIL: mixed — ip_cidr rule (idx 1) not emitted"; echo "$out"; exit 1; }
# domain_suffix rule (idx 0) must not create a set
echo "$out" | grep -q "set rs_test_mixed_0_v4" \
	&& { echo "FAIL: mixed — domain-only rule produced an unexpected set"; exit 1; }
rm -f /tmp/singbox-ui/rs_test_mixed.json

echo "-- emit with two interfaces: wan_ifaces set contains both"
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" emit 7893 "198.18.0.0/15" "" "br-lan,br-guest")
echo "$out" | grep -q 'set wan_ifaces' \
    || { echo "FAIL: missing wan_ifaces set for 2 ifaces"; echo "$out"; exit 1; }
echo "$out" | grep -q '"br-lan"' \
    || { echo "FAIL: br-lan missing from wan_ifaces"; echo "$out"; exit 1; }
echo "$out" | grep -q '"br-guest"' \
    || { echo "FAIL: br-guest missing from wan_ifaces"; echo "$out"; exit 1; }
echo "  PASS: multi-iface emits named set"

echo "-- emit with three interfaces"
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" emit 7893 "198.18.0.0/15" "" "br-lan,br-guest,wlan0")
echo "$out" | grep -q '"wlan0"' \
    || { echo "FAIL: wlan0 missing from wan_ifaces"; echo "$out"; exit 1; }
echo "  PASS: three-iface emits named set"

echo "-- emit with single interface: wan_ifaces set contains it"
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" emit 7893 "198.18.0.0/15" "" "br-lan")
echo "$out" | grep -q 'set wan_ifaces' \
    || { echo "FAIL: missing wan_ifaces set for single iface"; exit 1; }
echo "$out" | grep -q '"br-lan"' \
    || { echo "FAIL: br-lan missing from wan_ifaces"; exit 1; }
echo "  PASS: single-iface in named set"

echo "-- C2.1.6: iface names with quotes/spaces/shell metacharacters are dropped"
# emit's iface_str is comma-split; a hostile name with embedded quotes would
# otherwise break out of the iifname "..." string and inject arbitrary nft.
# Valid neighbours must survive; invalid ones must be filtered with a warning.
# We split stdout (the emitted nft script) from stderr (the warning) so the
# "bad iface" grep only matches if the name reached the nft text.
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" emit 7893 "198.18.0.0/15" "" 'br-lan,evil"; ls #,wan0' 2>/tmp/c2_iface_err.log)
err=$(cat /tmp/c2_iface_err.log)
rm -f /tmp/c2_iface_err.log
echo "$out" | grep -q 'evil' \
    && { echo "FAIL: bad iface made it through to nft"; echo "$out"; exit 1; }
echo "$out" | grep -q '"br-lan"' \
    || { echo "FAIL: valid iface br-lan was dropped"; echo "$out"; exit 1; }
echo "$out" | grep -q '"wan0"' \
    || { echo "FAIL: valid iface wan0 was dropped"; echo "$out"; exit 1; }
echo "$err" | grep -qi 'invalid iface\|iface.*skip' \
    || { echo "FAIL: no warning emitted for filtered iface"; echo "stderr: $err"; exit 1; }
echo "  PASS: bad iface filtered + warning emitted"

echo "-- C2.1.6: iface name with backslash is dropped"
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" emit 7893 "198.18.0.0/15" "" 'br-lan,bad\name' 2>/dev/null)
echo "$out" | grep -q 'bad\\name\|bad\\\\name' \
    && { echo "FAIL: backslash iface made it through"; echo "$out"; exit 1; }
echo "  PASS: backslash iface filtered"

echo "-- C2.1.6: dotted/at-sign iface names are accepted (vlan, alias forms)"
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" emit 7893 "198.18.0.0/15" "" 'eth0.100,br-lan@if5' 2>/dev/null)
echo "$out" | grep -q 'eth0.100' \
    || { echo "FAIL: dotted iface dropped (should be valid)"; echo "$out"; exit 1; }
echo "$out" | grep -q 'br-lan@if5' \
    || { echo "FAIL: @-iface dropped (should be valid)"; echo "$out"; exit 1; }
echo "  PASS: dotted/at-sign iface names accepted"

echo "-- emit: extra fwmark/fwmask/router_out argv accepted (defaults applied when missing)"
# shellcheck disable=SC2086
"$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" emit 7895 198.18.0.0/15 fc00::/18 br-lan \
	>/tmp/emit-default.nft
# shellcheck disable=SC2086
"$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" emit 7895 198.18.0.0/15 fc00::/18 br-lan 0x1 0x1 0 \
	>/tmp/emit-explicit.nft
if ! cmp -s /tmp/emit-default.nft /tmp/emit-explicit.nft; then
	echo "FAIL: default emit differs from explicit-default emit"
	exit 1
fi
rm -f /tmp/emit-default.nft /tmp/emit-explicit.nft
echo "ok"

echo "OK"
