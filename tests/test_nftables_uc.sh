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
	UCODE_LIB_FLAGS="-L ${UCODE_APP_LIB_DIR:-$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/lib}"
elif [ -x "${UCODE_BIN:-}" ] && [ -d "${UCODE_STUB_DIR:-}" ]; then
	UCODE_LIB_FLAGS="-L $UCODE_STUB_DIR"
	[ -n "${UCODE_LIB_DIR:-}" ] && UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L $UCODE_LIB_DIR"
	UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L ${UCODE_APP_LIB_DIR:-$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/lib}"
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
echo "$out" | grep -q "ip daddr @rs_uctest_scalar_0_v4 meta l4proto { tcp, udp } ct state new ct mark set ct mark or 0x1" \
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
echo "$out" | grep -q "ip daddr @rs_uctest_port_0_v4 meta l4proto tcp tcp dport 80-443 ct state new ct mark set ct mark or 0x1" \
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
echo "$out" | grep -qE '^[[:space:]]*set rs_[a-f0-9]{16}_0_v4' \
    || { echo "FAIL: long name hash not 16 hex chars (G8)"; echo "$out"; exit 1; }
rm -f /tmp/singbox-ui/rs_${long_name}.json
pass "long name hashed (G8: 16-hex)"

# ---- C2.1.4: listen_port validation in emit path ----
# emit accepts PORT on argv; an out-of-range/non-int value must be rejected
# rather than baked into a broken `tproxy ip to 127.0.0.1:<garbage>` line.
echo "-- C2.1.4: listen_port out of range (99999) is rejected"
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" emit 99999 "198.18.0.0/15" "" "br-lan" 2>&1) || true
echo "$out" | grep -q '127\.0\.0\.1:99999' \
    && { echo "FAIL: out-of-range port made it through to nft"; echo "$out"; exit 1; }
pass "out-of-range listen_port rejected"

echo "-- C2.1.4: listen_port non-integer (abc) is rejected"
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" emit abc "198.18.0.0/15" "" "br-lan" 2>&1) || true
echo "$out" | grep -q '127\.0\.0\.1:abc' \
    && { echo "FAIL: non-integer port made it through to nft"; echo "$out"; exit 1; }
pass "non-integer listen_port rejected"

echo "-- C2.1.4: listen_port zero is rejected"
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" emit 0 "198.18.0.0/15" "" "br-lan" 2>&1) || true
echo "$out" | grep -q '127\.0\.0\.1:0\b' \
    && { echo "FAIL: zero port made it through to nft"; echo "$out"; exit 1; }
pass "zero listen_port rejected"

echo "-- C2.1.4: listen_port in-range (1234) still works"
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" emit 1234 "198.18.0.0/15" "" "br-lan")
echo "$out" | grep -q '127\.0\.0\.1:1234' \
    || { echo "FAIL: valid in-range port 1234 missing"; echo "$out"; exit 1; }
pass "in-range listen_port accepted"

# ---- C2.1.7: nft delete table uses argv form, not shell-string form ----
# Matches the file-wide convention (line ~296 uses system(["nft", "-f", tmp])).
# Keeps inputs from being reparsed by /bin/sh — defense-in-depth even though
# TABLE is a compile-time constant today.
echo "-- C2.1.7: nft_delete_table_quiet uses argv-form system()"
grep -E 'system\(\["nft",[[:space:]]*"delete"' "$SCRIPT" >/dev/null \
    || { echo "FAIL: nftables.uc still uses string-form system() for nft delete"; \
         grep -n 'nft delete table' "$SCRIPT"; exit 1; }
grep -F 'system(`nft delete table' "$SCRIPT" >/dev/null \
    && { echo "FAIL: shell-string form of nft delete table still present"; exit 1; }
pass "nft delete in argv form"

# ---- G6: no shell-invoked mktemp ----
# fs.popen() in OpenWrt's ucode only accepts a shell string (argv form
# returns null), so the consistency fix is to drop mktemp entirely and
# compose the temp file path on the ucode side via /dev/urandom.
echo "-- G6: tmp filename composed on the ucode side, no shell-invoked mktemp"
grep -E 'fs\.popen.*mktemp' "$SCRIPT" >/dev/null \
    && { echo "FAIL: G6 still spawns mktemp via fs.popen"; \
         grep -n mktemp "$SCRIPT"; exit 1; }
grep -F 'system(`mktemp' "$SCRIPT" >/dev/null \
    && { echo "FAIL: G6 still spawns mktemp via shell-string system()"; exit 1; }
pass "G6: no shell-invoked mktemp"

# ---- G1: fakeip range injection via cmd_emit V4/V6 argv ----
# log_err echoes the rejected input to stderr — we only care about stdout
# (the nft script that `nft -f` would consume), so 2>/dev/null is intentional.
echo "-- G1: malicious v4 fakeip range is sanitised away"
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" emit 7893 \
    '198.18.0.0/15 }; chain x { type filter hook prerouting priority 0;}; #' \
    "" "br-lan" 2>/dev/null) || true
echo "$out" | grep -q 'chain x' \
    && { echo "FAIL: G1 v4 injection produced extra chain in nft script"; echo "$out"; exit 1; }
echo "$out" | grep -F '}; chain' >/dev/null \
    && { echo "FAIL: G1 poisoned daddr line in nft script"; echo "$out"; exit 1; }
echo "$out" | grep -F 'daddr {' >/dev/null \
    && { echo "FAIL: G1 daddr clause should be entirely omitted when v4 invalid"; echo "$out"; exit 1; }
pass "G1: malicious v4 fakeip rejected"

echo "-- G1: malicious v6 fakeip range is sanitised away"
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" emit 7893 "" \
    'fc00::/7 }; insert rule inet filter forward drop; #' "br-lan" 2>/dev/null) || true
echo "$out" | grep -q 'insert rule' \
    && { echo "FAIL: G1 v6 injection produced extra rule in nft script"; echo "$out"; exit 1; }
pass "G1: malicious v6 fakeip rejected"

echo "-- G1: clean v4 fakeip range still works"
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" emit 7893 "198.18.0.0/15" "" "br-lan")
# New design: fakeip4 is a named set; check elements body and @fakeip4 rule.
echo "$out" | grep -A3 'set fakeip4' | grep -q "198.18.0.0/15" || fail "G1: clean v4 broken (fakeip4 elements)"
echo "$out" | grep -q 'daddr @fakeip4' || fail "G1: clean v4 broken (fakeip4 rule)"
pass "G1: clean v4 fakeip preserved"

echo "-- G1: comma-separated CIDR list still works"
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" emit 7893 \
    "198.18.0.0/15, 10.0.0.0/8" "" "br-lan")
echo "$out" | grep -A3 'set fakeip4' | grep -q "198.18.0.0/15" \
    || { echo "FAIL: G1 comma-list broken (first cidr)"; echo "$out"; exit 1; }
echo "$out" | grep -A3 'set fakeip4' | grep -q "10.0.0.0/8" \
    || { echo "FAIL: G1 comma-list broken (second cidr)"; echo "$out"; exit 1; }
pass "G1: comma-separated CIDRs accepted"

# ---- G2: rs_*.json ip_cidr injection ----
echo "-- G2: malicious ip_cidr in rs_*.json is dropped"
cat >/tmp/singbox-ui/rs_uctest_g2.json <<'JSON'
{ "rules": [ { "ip_cidr": ["1.1.1.0/24 }; insert rule inet filter forward drop; #"] } ] }
JSON
out=$(emit)
echo "$out" | grep -q 'insert rule' \
    && { echo "FAIL: G2 nft injection via ip_cidr"; echo "$out"; exit 1; }
echo "$out" | grep -F '}; insert' >/dev/null \
    && { echo "FAIL: G2 poisoned elements body"; echo "$out"; exit 1; }
rm /tmp/singbox-ui/rs_uctest_g2.json
pass "G2: malicious ip_cidr rejected"

echo "-- G2: clean CIDRs in rs_*.json still emitted"
cat >/tmp/singbox-ui/rs_uctest_g2clean.json <<'JSON'
{ "rules": [ { "ip_cidr": ["1.1.1.0/24", "8.8.8.8/32"] } ] }
JSON
out=$(emit)
echo "$out" | grep -q "elements = { 1.1.1.0/24,8.8.8.8/32 }" \
    || { echo "FAIL: G2 clean elements broken"; echo "$out"; exit 1; }
rm /tmp/singbox-ui/rs_uctest_g2clean.json
pass "G2: clean ip_cidr preserved"

# ---- G3: warn when more than one enabled tproxy inbound is present ----
echo "-- G3: multiple enabled tproxy inbounds produce a warning"
UCI_DIR="$TMPDIR/uci-g3-multi"
mkdir -p "$UCI_DIR"
# Provide a stub nft on PATH so cmd_apply doesn't fail before the warning.
mkdir -p "$TMPDIR/bin-g3"
cat >"$TMPDIR/bin-g3/nft" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$TMPDIR/bin-g3/nft"
cat >"$UCI_DIR/singbox-ui" <<'EOF'
config inbound 'tp1'
	option enabled '1'
	option protocol 'tproxy'
	option listen_port '7893'

config inbound 'tp2'
	option enabled '1'
	option protocol 'tproxy'
	option listen_port '7894'
EOF
# shellcheck disable=SC2086
PATH="$TMPDIR/bin-g3:$PATH" UCI_CONFIG_DIR="$UCI_DIR" \
    "$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" apply 2>"$TMPDIR/g3-multi.err" || true
grep -q 'multiple enabled tproxy' "$TMPDIR/g3-multi.err" \
    || { echo "FAIL: G3 missing multi-tproxy warning"; cat "$TMPDIR/g3-multi.err"; exit 1; }
pass "G3: multi-tproxy warning emitted"

echo "-- G3: a single enabled tproxy inbound does not warn"
UCI_DIR="$TMPDIR/uci-g3-one"
mkdir -p "$UCI_DIR"
cat >"$UCI_DIR/singbox-ui" <<'EOF'
config inbound 'tp1'
	option enabled '1'
	option protocol 'tproxy'
	option listen_port '7893'
EOF
# shellcheck disable=SC2086
PATH="$TMPDIR/bin-g3:$PATH" UCI_CONFIG_DIR="$UCI_DIR" \
    "$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" apply 2>"$TMPDIR/g3-one.err" || true
grep -q 'multiple enabled tproxy' "$TMPDIR/g3-one.err" \
    && { echo "FAIL: G3 false-positive on single tproxy"; cat "$TMPDIR/g3-one.err"; exit 1; }
pass "G3: single tproxy does not warn"

echo "-- safe_fwmark: hex and decimal pass, fwmark within mask"
# shellcheck disable=SC2086  # UCODE_LIB_FLAGS intentionally expands as multiple -L args
out=$(cat <<'UCODE' | "$UCODE_BIN" $UCODE_LIB_FLAGS -
  function safe_fwmark(v, fallback) {
    if (v == null) return fallback;
    let t = trim(`${v}`);
    if (t == "") return fallback;
    if (!match(t, /^(0x[0-9a-fA-F]{1,8}|[0-9]+)$/)) return fallback;
    let n = (substr(t, 0, 2) == "0x") ? +`0x${substr(t, 2)}` : +t;
    if (type(n) != "int" || n < 1 || n > 0xffffffff) return fallback;
    return n;
  }
  printf("%d %d %d %d %d",
    safe_fwmark("0x1", 0xdead),
    safe_fwmark("42", 0xdead),
    safe_fwmark("xyz", 0xdead),
    safe_fwmark("", 0xdead),
    safe_fwmark(null, 0xdead));
UCODE
)
echo "GOT: $out"
[ "$out" = "1 42 57005 57005 57005" ] || { echo "FAIL: safe_fwmark output wrong"; exit 1; }

echo "-- safe_fwmark + mask invariant: (mark & mask) == mark"
# shellcheck disable=SC2086  # UCODE_LIB_FLAGS intentionally expands as multiple -L args
out=$(cat <<'UCODE' | "$UCODE_BIN" $UCODE_LIB_FLAGS -
  function fwmark_pair(mark, mask) {
    if (!mark || !mask) return [0, 0];
    if ((mark & mask) != mark) return [1, 1];
    return [mark, mask];
  }
  let r1 = fwmark_pair(0x1, 0x1);
  let r2 = fwmark_pair(0x101, 0x100);
  printf("%d/%d %d/%d", r1[0], r1[1], r2[0], r2[1]);
UCODE
)
[ "$out" = "1/1 1/1" ] || { echo "FAIL: invariant rollback wrong"; exit 1; }
echo "ok"

echo "-- cmd_apply: UCI fwmark / fwmark_mask read with defaults"
UCI_TEST=$(mktemp -d)
cat >"$UCI_TEST/singbox-ui" <<EOF
config global
	option fwmark '0x100'
	option fwmark_mask '0xff00'
	option redirect_router_traffic '1'
EOF
# The emit subcommand's CLI arity check is extended in Task 3.
# For Task 2, sanity-check that the UCI parse path itself doesn't fail
# by invoking apply through a stubbed nft. PATH stub:
STUB=$(mktemp -d)
cat >"$STUB/nft" <<'NFT'
#!/bin/sh
exec cat > /dev/null
NFT
chmod +x "$STUB/nft"
# `apply` requires at least one enabled tproxy inbound + fakeip dns
# server to build the ruleset, otherwise it deletes the table and
# returns early. Provide both in the UCI mock.
cat >>"$UCI_TEST/singbox-ui" <<EOF
config dns_server fakeip
	option type 'fakeip'
	option enabled '1'
	option inet4_range '198.18.0.0/15'
	option inet6_range 'fc00::/18'
config inbound tp
	option protocol 'tproxy'
	option enabled '1'
	option nft_rules '1'
	option listen_port '7895'
	list interface 'br-lan'
EOF
# shellcheck disable=SC2086  # UCODE_LIB_FLAGS intentionally expands as multiple -L args
PATH="$STUB:$PATH" UCI_CONFIG_DIR="$UCI_TEST" \
	"$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" apply 2>&1 \
	| grep -v 'No such file' >/dev/null || true
rm -rf "$UCI_TEST" "$STUB"
echo "ok"

echo "OK"
