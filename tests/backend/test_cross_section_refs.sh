#!/bin/sh
# tests/backend/test_cross_section_refs.sh — behavioral cross-section reference
# validation against generate.uc output: multi-hop detour chains resolve;
# dns_rule.server / route resolve action -> dns_server tag resolves; rule-set
# tag resolution; dangling refs dropped; circular detour does not hang/crash.
set -eu
. "$(dirname "$0")/../lib/sb_helpers.sh"
cd "$(dirname "$0")/../.."
if command -v ucode >/dev/null 2>&1; then
	UCODE_BIN=ucode; UCODE_LIB_FLAGS="-L ${UCODE_APP_LIB_DIR:-$PWD/${SB_LIB}}"
elif [ -x "${UCODE_BIN:-}" ] && [ -d "${UCODE_STUB_DIR:-}" ]; then
	UCODE_LIB_FLAGS="-L $UCODE_STUB_DIR -L ${UCODE_APP_LIB_DIR:-$PWD/${SB_LIB}}"
	[ -n "${UCODE_LIB_DIR:-}" ] && UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L $UCODE_LIB_DIR"
else
	echo "SKIP: ucode not available (set UCODE_BIN + UCODE_STUB_DIR [+ UCODE_LIB_DIR] to run locally)"; exit 0
fi
GENERATE_UC=${SB_SHARE}/generate.uc
TMPDIR=$(mktemp -d); trap 'rm -rf "$TMPDIR"' EXIT
SANDBOX_DIR="$TMPDIR/sandbox"; SANDBOX_CONFIG="$SANDBOX_DIR/singbox-ui.json"; mkdir -p "$SANDBOX_DIR/subs"
write_cfg() { printf '%s\n' "$1" > "$TMPDIR/singbox-ui"; }
run_gen() {
	# shellcheck disable=SC2086
	UCI_CONFIG_DIR="$TMPDIR" SINGBOX_TMPDIR="$SANDBOX_DIR/subs" SINGBOX_CONFIG="$SANDBOX_CONFIG" \
		"$UCODE_BIN" $UCODE_LIB_FLAGS "$GENERATE_UC" >"$TMPDIR/gen.stderr" 2>&1 && cp "$SANDBOX_CONFIG" "$TMPDIR/out.json"
}
_jeval() {
	_expr="$1"; _file="$2"
	# shellcheck disable=SC2086
	"$UCODE_BIN" $UCODE_LIB_FLAGS -e '
		let fs=require("fs"); let f=fs.open(ARGV[0],"r"); let d=json(f.read("all")); f.close();
		let v; try { v=('"$_expr"'); } catch(e){ v=null; }
		if (v===null) print("<<UNDEF>>"); else if (type(v)=="bool") print(v?"true":"false"); else print(v);
	' "$_file"
}
jpath_eq() { _got=$(_jeval "$2" "$4"); [ "$_got" = "$3" ] || { echo "FAIL: $1 — [$2]='$_got' want '$3'"; cat "$4"; exit 1; }; echo "  PASS: $1"; }
jpath_true() { _got=$(_jeval "$2" "$3"); [ "$_got" = "true" ] || { echo "FAIL: $1 — [$2]='$_got' want true"; cat "$3"; exit 1; }; echo "  PASS: $1"; }

# ---- detour chain A->B->C resolves end-to-end ----
echo "-- detour chain A->B->C: each hop's bind/detour preserved"
write_cfg "
config outbound 'C'
	option enabled '1'
	option type 'interface'
	option interface 'eth0'

config outbound 'B'
	option enabled '1'
	option type 'socks'
	option server '10.0.0.2'
	option server_port '1080'
	option detour 'C'

config outbound 'A'
	option enabled '1'
	option type 'socks'
	option server '10.0.0.1'
	option server_port '1080'
	option detour 'B'
"
run_gen || { echo "FAIL: generate exited non-zero"; cat "$TMPDIR/gen.stderr"; exit 1; }
jpath_eq "A.detour==B" '(function(){for(let o in d.outbounds)if(o.tag=="A")return o.detour;return "<none>";})()' 'B' "$TMPDIR/out.json"
jpath_eq "B.detour==C" '(function(){for(let o in d.outbounds)if(o.tag=="B")return o.detour;return "<none>";})()' 'C' "$TMPDIR/out.json"

# ---- route_rule resolve action -> dns_server tag resolves ----
echo "-- route resolve action references a dns_server tag"
write_cfg "
config dns_server 'up'
	option enabled '1'
	option type 'udp'
	option server '1.1.1.1'

config inbound 'tp'
	option enabled '1'
	option protocol 'tproxy'
	option listen_port '7893'
	option hijack_dns '0'

config route_rule 'r_resolve'
	option enabled '1'
	option type 'default'
	option action 'resolve'
	option server 'up'
	list domain_suffix '.cn'
"
run_gen || { echo "FAIL: generate exited non-zero (resolve)"; cat "$TMPDIR/gen.stderr"; exit 1; }
jpath_true "a route rule resolves to server 'up'" '(function(){for(let r in d.route.rules)if(r.action=="resolve"&&r.server=="up")return true;return false;})()' "$TMPDIR/out.json"

# ---- dns_rule.server -> dns_server tag resolves; ruleset tag defined ----
echo "-- dns_rule.server + rule_set tag resolution"
write_cfg "
config dns_server 'fakeip'
	option enabled '1'
	option type 'fakeip'
	option inet4_range '198.18.0.0/15'

config ruleset 'cn'
	option enabled '1'
	option type 'remote'
	option url 'https://example.com/cn.srs'

config dns_rule 'cn_fakeip'
	option enabled '1'
	option type 'default'
	list rule_set 'cn'
	option action 'route'
	option server 'fakeip'
"
run_gen || { echo "FAIL: generate exited non-zero (dns_rule)"; cat "$TMPDIR/gen.stderr"; exit 1; }
jpath_true "dns rule routes to fakeip" '(function(){for(let r in d.dns.rules)if(r.server=="fakeip")return true;return false;})()' "$TMPDIR/out.json"
jpath_true "cn rule-set defined in route.rule_set" '(function(){for(let e in (d.route.rule_set||[]))if(e.tag=="cn")return true;return false;})()' "$TMPDIR/out.json"

# ---- circular detour A->B->A must not hang or crash; generate succeeds ----
echo "-- circular detour A->B->A: generate completes, both hops emitted"
write_cfg "
config outbound 'A'
	option enabled '1'
	option type 'socks'
	option server '10.0.0.1'
	option server_port '1080'
	option detour 'B'

config outbound 'B'
	option enabled '1'
	option type 'socks'
	option server '10.0.0.2'
	option server_port '1080'
	option detour 'A'
"
run_gen || { echo "FAIL: circular detour made generate exit non-zero (should not hang/crash)"; cat "$TMPDIR/gen.stderr"; exit 1; }
jpath_true "circular: A present" '(function(){for(let o in d.outbounds)if(o.tag=="A")return true;return false;})()' "$TMPDIR/out.json"
jpath_true "circular: B present" '(function(){for(let o in d.outbounds)if(o.tag=="B")return true;return false;})()' "$TMPDIR/out.json"

# ---- dangling detour: documents CURRENT behavior (NOT scrubbed today) ----
# GAP/finding: outbound->outbound `detour` pointing at a non-existent tag is NOT
# scrubbed. post_process.uc scrub_implicit_refs only scrubs references to
# IMPLICIT tags (e.g. "direct") and only for dns.servers[].detour / dns.detour /
# route.rules[].outbound / route.final. outbound.uc's dangling-drop validates
# only selector/urltest group members + `default`, never a plain outbound's
# `detour`. So `detour='ghost'` survives into the emitted config (sing-box would
# fatally reject it at load). This assert documents the gap rather than papering
# over it: generate must SUCCEED and 'real' must be present.
echo "-- dangling detour to a missing outbound: documents current (un-scrubbed) behavior"
write_cfg "
config outbound 'real'
	option enabled '1'
	option type 'socks'
	option server '10.0.0.1'
	option server_port '1080'
	option detour 'ghost'
"
run_gen || { echo "FAIL: generate exited non-zero (dangling detour)"; cat "$TMPDIR/gen.stderr"; exit 1; }
jpath_true "generate succeeds and 'real' is present (dangling detour un-scrubbed; see GAP note)" '(function(){for(let o in d.outbounds)if(o.tag=="real")return true;return false;})()' "$TMPDIR/out.json"
echo "OK"
