#!/bin/sh
# tests/test_nftables_uc.sh
# Unit tests for the rule-set JSON parser in nftables.uc. Drives the script
# via `emit` (the only subcommand that's pure-output and side-effect free)
# and asserts that the printed nft text reflects each rs_*.json shape.
set -e

# Mirror test_generate.sh / test_subscription_uc.sh: SKIP when ucode is
# unavailable on the dev box.
if command -v ucode >/dev/null 2>&1; then
	UCODE_BIN=ucode
	UCODE_LIB_FLAGS=""
elif [ -x "${UCODE_BIN:-}" ] && [ -d "${UCODE_STUB_DIR:-}" ]; then
	UCODE_LIB_FLAGS="-L $UCODE_STUB_DIR"
	[ -n "${UCODE_LIB_DIR:-}" ] && UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L $UCODE_LIB_DIR"
else
	echo "SKIP: ucode not available"
	exit 0
fi

SCRIPT=luci-app-singbox-ui/root/usr/share/singbox-ui/nftables.uc
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"; rm -f /tmp/singbox-ui/rs_uctest_*.json' EXIT

mkdir -p /tmp/singbox-ui
rm -f /tmp/singbox-ui/rs_uctest_*.json

emit() {
	# shellcheck disable=SC2086
	"$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" emit 7893 "198.18.0.0/15" "" "br-lan"
}

pass() { echo "  PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

# ---- empty cache → no rs_ sets ----
echo "-- empty cache → emit succeeds with no rs_ sets"
out=$(emit)
echo "$out" | grep -q "table inet singbox_ui" || fail "no table"
echo "$out" | grep -q "set rs_" && fail "unexpected rs_ set on empty cache"
pass "empty cache"

# ---- scalar ip_cidr ----
echo "-- scalar ip_cidr emits one set with one element"
cat >/tmp/singbox-ui/rs_uctest_scalar.json <<'JSON'
{ "rules": [ { "ip_cidr": "104.16.0.0/12" } ] }
JSON
out=$(emit)
echo "$out" | grep -q "set rs_uctest_scalar_0_v4" || fail "scalar: set missing"
echo "$out" | grep -q "elements = { 104.16.0.0/12 }" || fail "scalar: element body wrong"
echo "$out" | grep -q "ip daddr @rs_uctest_scalar_0_v4 meta l4proto { tcp, udp } ct state new meta mark set 0x1" \
	|| fail "scalar: marking rule wrong"
rm /tmp/singbox-ui/rs_uctest_scalar.json
pass "scalar ip_cidr"

# ---- array ip_cidr + mixed v4/v6 ----
echo "-- array ip_cidr with mixed v4 and v6 splits into two sets"
cat >/tmp/singbox-ui/rs_uctest_mixed.json <<'JSON'
{ "rules": [ { "ip_cidr": ["1.2.3.0/24", "fe80::/10", "4.5.0.0/16"] } ] }
JSON
out=$(emit)
echo "$out" | grep -q "set rs_uctest_mixed_0_v4" || fail "mixed: v4 set missing"
echo "$out" | grep -q "set rs_uctest_mixed_0_v6" || fail "mixed: v6 set missing"
echo "$out" | grep -q "elements = { 1.2.3.0/24,4.5.0.0/16 }" || fail "mixed: v4 elements wrong"
echo "$out" | grep -q "elements = { fe80::/10 }" || fail "mixed: v6 elements wrong"
echo "$out" | grep -q "ip6 daddr @rs_uctest_mixed_0_v6" || fail "mixed: v6 rule missing"
rm /tmp/singbox-ui/rs_uctest_mixed.json
pass "mixed v4/v6"

# ---- network=tcp + scalar port_range ----
echo "-- network=tcp + scalar port_range '80:443' produces 'tcp dport 80-443'"
cat >/tmp/singbox-ui/rs_uctest_port.json <<'JSON'
{ "rules": [ { "ip_cidr": "10.0.0.0/8", "network": "tcp", "port_range": "80:443" } ] }
JSON
out=$(emit)
echo "$out" | grep -q "ip daddr @rs_uctest_port_0_v4 meta l4proto tcp tcp dport 80-443 ct state new meta mark set 0x1" \
	|| { echo "$out"; fail "port: marking rule wrong"; }
rm /tmp/singbox-ui/rs_uctest_port.json
pass "tcp + scalar port_range"

# ---- network=udp + array port_range ----
echo "-- network=udp + array port_range emits brace-listed udp dport set"
cat >/tmp/singbox-ui/rs_uctest_ports.json <<'JSON'
{ "rules": [ { "ip_cidr": "10.0.0.0/8", "network": "udp", "port_range": ["53", "853"] } ] }
JSON
out=$(emit)
echo "$out" | grep -q "udp dport { 53, 853 }" || { echo "$out"; fail "ports: brace set wrong"; }
rm /tmp/singbox-ui/rs_uctest_ports.json
pass "udp + array port_range"

# ---- domain-only rule is skipped, ip_cidr rule still emits ----
echo "-- domain-only rule is skipped"
cat >/tmp/singbox-ui/rs_uctest_dom.json <<'JSON'
{ "rules": [ { "domain_suffix": ["x"] }, { "ip_cidr": "10.0.0.0/8" } ] }
JSON
out=$(emit)
echo "$out" | grep -q "set rs_uctest_dom_0_v4" && fail "dom: domain rule should not produce a set"
echo "$out" | grep -q "set rs_uctest_dom_1_v4" || fail "dom: ip_cidr rule (idx 1) missing"
rm /tmp/singbox-ui/rs_uctest_dom.json
pass "domain-only skipped"

# ---- malformed JSON does not abort run ----
echo "-- malformed rs_*.json is silently skipped"
echo "{ this is not json" > /tmp/singbox-ui/rs_uctest_bad.json
out=$(emit) || fail "bad JSON aborted emit"
echo "$out" | grep -q "table inet singbox_ui" || fail "bad: table still emitted"
rm /tmp/singbox-ui/rs_uctest_bad.json
pass "malformed JSON skipped"

# ---- emitted ruleset prefixes table with atomic transaction (add/delete/table) ----
echo "-- atomic replace: 'add table' + 'delete table' prelude before 'table {' declaration"
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" emit 7893 "198.18.0.0/15" "" "br-lan")
add_ln=$(printf    "%s\n" "$out" | grep -n '^add table inet singbox_ui'    | head -n1 | cut -d: -f1)
delete_ln=$(printf "%s\n" "$out" | grep -n '^delete table inet singbox_ui' | head -n1 | cut -d: -f1)
table_ln=$(printf  "%s\n" "$out" | grep -n '^table inet singbox_ui {'      | head -n1 | cut -d: -f1)
[ -n "$add_ln"    ] || fail "no 'add table inet singbox_ui' prelude"
[ -n "$delete_ln" ] || fail "no 'delete table inet singbox_ui' prelude"
[ -n "$table_ln"  ] || fail "no 'table inet singbox_ui {' declaration"
[ "$add_ln"    -lt "$delete_ln" ] || fail "add (line $add_ln) must precede delete (line $delete_ln)"
[ "$delete_ln" -lt "$table_ln"  ] || fail "delete (line $delete_ln) must precede table { (line $table_ln)"
pass "atomic prelude present (add=$add_ln, delete=$delete_ln, table={=$table_ln)"

# ---- long ruleset name → hashed set name ----
echo "-- long ruleset name produces hashed set name ≤ 31 bytes"
long_name="extremelyverylongnamemorethanthirtybytes"
cat >/tmp/singbox-ui/rs_${long_name}.json <<'JSON'
{ "rules": [ { "ip_cidr": "10.0.0.0/8" } ] }
JSON
out=$(emit)
# Every emitted `set rs_...` name must fit nft's 31-byte limit.
echo "$out" | awk '/^[[:space:]]*set rs_/ {print $2}' | while read -r nm; do
    if [ "${#nm}" -gt 31 ]; then
        echo "FAIL: nft set name '$nm' is ${#nm} bytes (max 31)"
        exit 1
    fi
done
echo "$out" | grep -qE '^[[:space:]]*set rs_[a-f0-9]{12}_0_v4' \
    || { echo "FAIL: long name not hashed"; echo "$out"; exit 1; }
rm -f /tmp/singbox-ui/rs_${long_name}.json
pass "long name hashed"

echo "OK"
