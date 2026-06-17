#!/bin/sh
# tests/backend/test_generate_e2e.sh — generate.uc through the EXACT prod argv
# (ucode -L <lib> generate.uc, env UCI_CONFIG_DIR/SINGBOX_TMPDIR/SINGBOX_CONFIG)
# on one representative full config; asserts every top-level section is present
# at its exact path and that sing-box check accepts it.
set -eu
. "$(dirname "$0")/../lib/sb_helpers.sh"
cd "$(dirname "$0")/../.."

if command -v ucode >/dev/null 2>&1; then
	UCODE_BIN=ucode
	UCODE_LIB_FLAGS="-L ${UCODE_APP_LIB_DIR:-$PWD/${SB_LIB}}"
elif [ -x "${UCODE_BIN:-}" ] && [ -d "${UCODE_STUB_DIR:-}" ]; then
	UCODE_LIB_FLAGS="-L $UCODE_STUB_DIR -L ${UCODE_APP_LIB_DIR:-$PWD/${SB_LIB}}"
	[ -n "${UCODE_LIB_DIR:-}" ] && UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L $UCODE_LIB_DIR"
else
	echo "SKIP: ucode not available (set UCODE_BIN + UCODE_STUB_DIR [+ UCODE_LIB_DIR] to run locally)"
	exit 0
fi

GENERATE_UC=${SB_SHARE}/generate.uc
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
SANDBOX_DIR="$TMPDIR/sandbox"; SANDBOX_CONFIG="$SANDBOX_DIR/singbox-ui.json"
mkdir -p "$SANDBOX_DIR/subs"

write_cfg() { printf '%s\n' "$1" > "$TMPDIR/singbox-ui"; }
run_gen() {
	# shellcheck disable=SC2086
	UCI_CONFIG_DIR="$TMPDIR" SINGBOX_TMPDIR="$SANDBOX_DIR/subs" SINGBOX_CONFIG="$SANDBOX_CONFIG" \
		"$UCODE_BIN" $UCODE_LIB_FLAGS "$GENERATE_UC" >"$TMPDIR/gen.stderr" 2>&1 \
		&& cp "$SANDBOX_CONFIG" "$TMPDIR/out.json"
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
sb_check() {
	command -v sing-box >/dev/null 2>&1 || { echo "  SKIP sing-box check ($1) — sing-box absent"; return 0; }
	sing-box check -c "$2" >"$TMPDIR/sb.err" 2>&1 || { echo "FAIL: sing-box check rejected $1"; cat "$TMPDIR/sb.err"; cat "$2"; exit 1; }
	echo "  PASS: sing-box check accepts $1"
}

echo "-- representative full config through prod argv"
write_cfg "
config log 'log'
	option enabled '1'
	option level 'info'

config dns_server 'google'
	option enabled '1'
	option type 'https'
	option server '8.8.8.8'
	option server_port '443'
	option path '/dns-query'

config dns_server 'fakeip'
	option enabled '1'
	option type 'fakeip'
	option inet4_range '198.18.0.0/15'
	option inet6_range 'fc00::/18'

config dns 'dns'
	option final 'google'
	option strategy 'prefer_ipv4'

config inbound 'tproxy_in'
	option enabled '1'
	option protocol 'tproxy'
	option listen_port '7893'
	option hijack_dns '1'

config inbound 'mixed_in'
	option enabled '1'
	option protocol 'mixed'
	option listen_port '1080'

config outbound 'my_vless'
	option enabled '1'
	option type 'url'
	option proxy_url 'vless://aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee@vless.example.com:443?security=tls&sni=vless.example.com'

config outbound 'group'
	option enabled '1'
	option type 'selector'
	list group_outbounds 'my_vless'
	option group_default 'my_vless'

config ruleset 'geosite_cn'
	option enabled '1'
	option type 'remote'
	option url 'https://example.com/geosite-cn.srs'
	option format 'binary'

config route_rule 'rule_cn'
	option enabled '1'
	list rule_set 'geosite_cn'
	option action 'route'
	option outbound 'group'

config dns_rule 'cn_fakeip'
	option enabled '1'
	option type 'default'
	list rule_set 'geosite_cn'
	option action 'route'
	option server 'fakeip'

config route_default 'route_default'
	option action 'route'
	option outbound 'group'

config cache 'cache'
	option enabled '1'

config clash_api 'clash_api'
	option enabled '1'
	option listen '127.0.0.1'
	option port '9090'
	option secret 'sekret'
"
run_gen || { echo "FAIL: generate.uc exited non-zero"; cat "$TMPDIR/gen.stderr"; exit 1; }

# top-level JSON is well-formed (json() parse implicit in _jeval) + every section present at its exact path
jpath_eq   "log.level"                 'd.log.level'                             'info'             "$TMPDIR/out.json"
jpath_true "dns.servers is array"      '(type(d.dns.servers)=="array")'                            "$TMPDIR/out.json"
jpath_eq   "dns.final"                 'd.dns.final'                             'google'           "$TMPDIR/out.json"
jpath_true "inbounds present"          '(length(d.inbounds)>=2)'                                   "$TMPDIR/out.json"
jpath_true "outbounds present"         '(length(d.outbounds)>=1)'                                  "$TMPDIR/out.json"
jpath_eq   "route.rules[0].action"     'd.route.rules[0].action'                'hijack-dns'       "$TMPDIR/out.json"
jpath_true "route.rule_set present"    '(type(d.route.rule_set)=="array" && length(d.route.rule_set)>=1)' "$TMPDIR/out.json"
jpath_true "dns.rules present"         '(type(d.dns.rules)=="array" && length(d.dns.rules)>=1)'    "$TMPDIR/out.json"
jpath_true "selector group emitted"    '(function(){for(let o in d.outbounds)if(o.tag=="group")return o.type=="selector";return false;})()' "$TMPDIR/out.json"
jpath_eq   "experimental.clash_api"    'd.experimental.clash_api.external_controller' '127.0.0.1:9090' "$TMPDIR/out.json"
jpath_true "experimental.cache_file"   '(type(d.experimental.cache_file)=="object")'               "$TMPDIR/out.json"

sb_check "representative full config" "$TMPDIR/out.json"
echo "OK"
