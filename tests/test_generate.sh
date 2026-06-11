#!/bin/sh
# tests/test_generate.sh
# Smoke-tests generate.uc end-to-end. Requires ucode + ucode-mod-uci.
# Skips automatically on dev machines where ucode is unavailable.
set -e

# Local dev fallback: if `ucode` isn't on PATH, look for a locally-built one and
# our test stub for the uci module. Allows running tests on Ubuntu/WSL where
# ucode-mod-uci isn't packaged.
if command -v ucode >/dev/null 2>&1; then
	UCODE_BIN=ucode
	UCODE_LIB_FLAGS="-L ${UCODE_APP_LIB_DIR:-$PWD/luci-singbox-ui/root/usr/share/singbox-ui/lib}"
elif [ -x "${UCODE_BIN:-}" ] && [ -d "${UCODE_STUB_DIR:-}" ]; then
	UCODE_LIB_FLAGS="-L $UCODE_STUB_DIR -L ${UCODE_APP_LIB_DIR:-$PWD/luci-singbox-ui/root/usr/share/singbox-ui/lib}"
	[ -n "${UCODE_LIB_DIR:-}" ] && UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L $UCODE_LIB_DIR"
else
	echo "SKIP: ucode not available (set UCODE_BIN + UCODE_STUB_DIR [+ UCODE_LIB_DIR] to run locally)"
	exit 0
fi

GENERATE_UC=luci-singbox-ui/root/usr/share/singbox-ui/generate.uc
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

check() {
	desc="$1"; pattern="$2"; file="$3"
	grep -q "$pattern" "$file" \
		|| { echo "FAIL: $desc — '$pattern' not found in $file"; cat "$file"; exit 1; }
	echo "  PASS: $desc"
}

# Hand the freshly-generated config to the actual sing-box daemon's
# config validator. Catches the "shape looks right but sing-box rejects
# it" class of bugs that grep-substring assertions miss (the canonical
# example is the DNS-detour-to-implicit-direct crash). Skipped when
# sing-box isn't installed (e.g. plain host runs); always available in
# the Docker test env that CI uses.
sb_check() {
	desc="$1"; cfg="$2"
	command -v sing-box >/dev/null 2>&1 || return 0
	if ! sing-box check -c "$cfg" >"$TMPDIR/sb.err" 2>&1; then
		echo "FAIL: sing-box check rejected $desc"
		cat "$TMPDIR/sb.err"
		echo "--- generated config ---"
		cat "$cfg"
		exit 1
	fi
	echo "  PASS: sing-box check accepts $desc"
}

write_cfg() { printf '%s\n' "$1" > "$TMPDIR/singbox-ui"; }

# Sandbox dir for sub_*.txt and the output config — keeps tests independent
# of any real /tmp/singbox-ui state on the host.
SANDBOX_DIR="$TMPDIR/sandbox"
SANDBOX_CONFIG="$SANDBOX_DIR/singbox-ui.json"
mkdir -p "$SANDBOX_DIR/subs"

run_gen() {
	# shellcheck disable=SC2086
	UCI_CONFIG_DIR="$TMPDIR" \
	SINGBOX_TMPDIR="$SANDBOX_DIR/subs" \
	SINGBOX_CONFIG="$SANDBOX_CONFIG" \
	"$UCODE_BIN" $UCODE_LIB_FLAGS "$GENERATE_UC" >"$TMPDIR/gen.stderr" 2>&1 \
		&& cp "$SANDBOX_CONFIG" "$TMPDIR/out.json"
}

# ---- fakeip (dns_server) + tproxy inbound ----
echo "-- fakeip dns_server + tproxy inbound"
write_cfg "
config dns_server 'fakeip'
	option enabled '1'
	option type 'fakeip'
	option inet4_range '198.18.0.0/15'
	option inet6_range 'fc00::/18'

config inbound 'tproxy_in'
	option enabled '1'
	option protocol 'tproxy'
	option listen_port '7893'
"
run_gen
check "fakeip type"       '"type": "fakeip"'              "$TMPDIR/out.json"
check "inet4_range str"   '"inet4_range": "198.18.0.0/15"' "$TMPDIR/out.json"
check "inet6_range str"   '"inet6_range": "fc00::/18"'     "$TMPDIR/out.json"
check "tproxy inbound"    '"type": "tproxy"'              "$TMPDIR/out.json"
check "listen_port 7893"  '"listen_port": 7893'           "$TMPDIR/out.json"
# Negative: must NOT emit as an array (sing-box 1.12+ rejects arrays here)
grep -q '"inet4_range":\s*\[' "$TMPDIR/out.json" \
	&& { echo "FAIL: inet4_range must be a string, not an array"; cat "$TMPDIR/out.json"; exit 1; }
echo "  PASS: inet4_range is not an array"
# NOTE: bare fakeip scenario is intentionally minimal for shape-testing
# and is NOT a valid sing-box config on its own (no upstream DNS). The
# sb_check assertions are placed on scenarios that build complete
# daemon-runnable configs.

# Phase C2 (atomic publish): no .tmp.* siblings of the final config should
# remain after a successful generate. The implementation writes to
# <CONFIG_OUT>.tmp.<time>.<n> and fs.renames atomically.
final_dir=$(dirname "$SANDBOX_CONFIG")
final_base=$(basename "$SANDBOX_CONFIG")
orphans=$(find "$final_dir" -maxdepth 1 -name "${final_base}.tmp.*" 2>/dev/null | wc -l)
[ "$orphans" -eq 0 ] || { echo "FAIL: $orphans orphan tmpfiles after generate"; ls -la "$final_dir"; exit 1; }
echo "  PASS: no orphan tmpfiles after happy-path generate"

# Atomic publish also requires the implementation actually use a tmp+rename
# pattern (not a direct write that would trivially produce no .tmp.* orphans).
# Assert generate.uc references publish_atomic / fs.rename so a future refactor
# that drops atomicity is caught immediately.
grep -q 'fs.rename' "$GENERATE_UC" \
	|| { echo "FAIL: generate.uc must use fs.rename for atomic publish"; exit 1; }
grep -q 'publish_atomic\|\.tmp\.' "$GENERATE_UC" \
	|| { echo "FAIL: generate.uc must use a tmp-suffixed publish path"; exit 1; }
echo "  PASS: generate.uc uses atomic publish (fs.rename + tmp path)"

# Phase C2: write failure must not leak a tmpfile. We force fs.open(tmp,'w')
# to fail by pointing SINGBOX_CONFIG at a path under a non-existent parent
# directory. generate.uc must exit non-zero AND leave nothing behind.
echo "-- atomic publish: no tmp leak when cannot open tmpfile"
bad_dir="$TMPDIR/does-not-exist/sub"
# shellcheck disable=SC2086
UCI_CONFIG_DIR="$TMPDIR" \
SINGBOX_TMPDIR="$SANDBOX_DIR/subs" \
SINGBOX_CONFIG="$bad_dir/config.json" \
"$UCODE_BIN" $UCODE_LIB_FLAGS "$GENERATE_UC" >"$TMPDIR/gen-fail.stderr" 2>&1 \
	&& { echo "FAIL: expected non-zero exit when tmpfile parent missing"; exit 1; }
# bad_dir itself was never created, so anything matching .tmp.* there would be
# a real bug. Search broadly under TMPDIR to catch any rogue writes.
leaked=$(find "$TMPDIR" -name 'config.json.tmp.*' 2>/dev/null | wc -l)
[ "$leaked" -eq 0 ] || { echo "FAIL: $leaked tmpfile(s) leaked on failed generate"; find "$TMPDIR" -name 'config.json.tmp.*'; exit 1; }
echo "  PASS: no tmpfile leaked on failed generate"

# ---- proxy via interface ----
echo "-- proxy via interface"
write_cfg "
config outbound 'via_wg0'
	option type 'interface'
	option interface 'wg0'
"
run_gen
check "interface proxy tag"  '"tag": "via_wg0"'         "$TMPDIR/out.json"
# Outside an OpenWrt netifd/ubus environment the resolver falls back to the
# input verbatim, so a literal "wg0" still flows through unchanged.
check "bind_interface"       '"bind_interface": "wg0"'  "$TMPDIR/out.json"

echo "-- bind_interface honours SINGBOX_DEV_<iface> resolver override"
write_cfg "
config outbound 'wan_out'
	option type 'interface'
	option interface 'wan'
"
SINGBOX_DEV_wan=eth0 run_gen
check "wan→eth0 via env" '"bind_interface": "eth0"' "$TMPDIR/out.json"

# ---- vless URL ----
echo "-- vless:// URL"
write_cfg "
config outbound 'my_vless'
	option type 'url'
	option proxy_url 'vless://test-uuid-1234@example.com:443?security=tls&sni=example.com&type=tcp'
"
run_gen
check "vless type"   '"type": "vless"'          "$TMPDIR/out.json"
check "vless uuid"   '"uuid": "test-uuid-1234"' "$TMPDIR/out.json"
check "vless server" '"server": "example.com"'  "$TMPDIR/out.json"
check "vless port"   '"server_port": 443'        "$TMPDIR/out.json"
check "vless tls"    '"enabled": true'           "$TMPDIR/out.json"

# ---- hy2 URL ----
echo "-- hy2:// URL"
write_cfg "
config outbound 'my_hy2'
	option type 'url'
	option proxy_url 'hy2://mypassword@vpn.example.com:8443?sni=vpn.example.com'
"
run_gen
check "hy2 type"     '"type": "hysteria2"'         "$TMPDIR/out.json"
check "hy2 password" '"password": "mypassword"'    "$TMPDIR/out.json"
check "hy2 server"   '"server": "vpn.example.com"' "$TMPDIR/out.json"

# ---- outbound without type is skipped (no longer a valid outbound) ----
echo "-- outbound without type is skipped"
write_cfg "
config outbound 'leftover_direct_out'
	option action 'direct'
"
run_gen
grep -q '"tag": "leftover_direct_out"' "$TMPDIR/out.json" \
	&& { echo "FAIL: outbound without type must be skipped"; cat "$TMPDIR/out.json"; exit 1; }
echo "  PASS: outbound without type is skipped"

# ---- subscription outbound ----
echo "-- type=subscription"
printf 'vless://sub-uuid-9999@sub.example.com:443?security=tls&sni=sub.example.com\n' \
	> "$SANDBOX_DIR/subs/sub_my_sub_out.txt"
write_cfg "
config outbound 'my_sub_out'
	option enabled '1'
	option type 'subscription'
	option sub_url 'https://sub.example.com/config'
	option sub_update_via 'direct'
	option sub_interval '3600'
"
run_gen
check "sub tag"    '"tag": "my_sub_out"'         "$TMPDIR/out.json"
check "sub type"   '"type": "vless"'             "$TMPDIR/out.json"
check "sub uuid"   '"uuid": "sub-uuid-9999"'     "$TMPDIR/out.json"
check "sub server" '"server": "sub.example.com"' "$TMPDIR/out.json"

# ---- ruleset + route_rule basic flow ----
echo "-- ruleset + route_rule basic"
write_cfg "
config outbound 'my_vless'
	option enabled '1'
	option type 'url'
	option proxy_url 'vless://uuid-aaaa@vless.example.com:443?security=tls&sni=vless.example.com'

config ruleset 'geosite_cn'
	option enabled '1'
	option type 'remote'
	option url 'https://example.com/geosite-cn.srs'
	option format 'binary'

config ruleset 'geoip_ru'
	option enabled '1'
	option type 'local'
	option path '/etc/singbox-ui/rules/ru.json'
	option format 'source'

config route_rule 'rule_cn_vless'
	option enabled '1'
	list ruleset 'geosite_cn'
	option action 'outbound'
	option outbound 'my_vless'

config route_rule 'rule_ru_direct'
	option enabled '1'
	list ruleset 'geoip_ru'
	option action 'direct'
"
run_gen
check "route rules key"       '\"rules\":'                              "$TMPDIR/out.json"
check "rule_set key"          '\"rule_set\":'                           "$TMPDIR/out.json"
check "cn tag"                '"tag": "geosite_cn"'                     "$TMPDIR/out.json"
check "ru tag"                '"tag": "geoip_ru"'                       "$TMPDIR/out.json"
check "cn remote type"        '"type": "remote"'                        "$TMPDIR/out.json"
check "ru local type"         '"type": "local"'                         "$TMPDIR/out.json"
check "ru local path"         '"path": "/etc/singbox-ui/rules/ru.json"' "$TMPDIR/out.json"
check "cn binary format"      '"format": "binary"'                      "$TMPDIR/out.json"
check "ru source format"      '"format": "source"'                      "$TMPDIR/out.json"
check "route rule cn->vless"  '"outbound": "my_vless"'                  "$TMPDIR/out.json"
check "route rule ru->direct" '"outbound": "direct"'                    "$TMPDIR/out.json"

# ---- remote ruleset update_interval -> sing-box rule_set (auto-update independent of nft_rules) ----
# A remote rule-set with update_interval set must emit "update_interval" in its
# route.rule_set entry so sing-box auto-updates it — even when "Create nftables
# rules" (nft_rules) is OFF. UI seconds map to a sing-box duration ("<n>s").
echo "-- ruleset update_interval -> rule_set"
write_cfg "
config ruleset 'auto_rs'
	option enabled '1'
	option type 'remote'
	option url 'https://example.com/auto.srs'
	option format 'binary'
	option nft_rules '0'
	option update_interval '86400'

config ruleset 'no_iv_rs'
	option enabled '1'
	option type 'remote'
	option url 'https://example.com/noiv.srs'
	option format 'binary'

config route_rule 'rule_auto'
	option enabled '1'
	list ruleset 'auto_rs'
	list ruleset 'no_iv_rs'
	option action 'direct'
"
run_gen
check "update_interval emitted as duration" '"update_interval": "86400s"' "$TMPDIR/out.json"
# A ruleset without update_interval must NOT receive the key — so exactly one occurrence.
n_iv=$(grep -c '"update_interval"' "$TMPDIR/out.json")
[ "$n_iv" = "1" ] \
	|| { echo "FAIL: expected exactly one update_interval (no_iv_rs must omit it), got $n_iv"; cat "$TMPDIR/out.json"; exit 1; }
echo "  PASS: update_interval propagated only when set"

# ---- disabled ruleset skipped ----
echo "-- disabled ruleset skipped"
write_cfg "
config ruleset 'geo_off'
	option enabled '0'
	option type 'remote'
	option url 'https://example.com/off.srs'
	option format 'binary'

config ruleset 'geo_on'
	option enabled '1'
	option type 'remote'
	option url 'https://example.com/on.srs'
	option format 'binary'

config route_rule 'rule_mix'
	option enabled '1'
	list ruleset 'geo_off'
	list ruleset 'geo_on'
	option action 'direct'
"
run_gen
check "enabled ruleset present" '"tag": "geo_on"' "$TMPDIR/out.json"
grep -q '"tag": "geo_off"' "$TMPDIR/out.json" \
	&& { echo "FAIL: disabled ruleset must not appear"; cat "$TMPDIR/out.json"; exit 1; }
echo "  PASS: disabled ruleset skipped"

# ---- duplicate rule_set entries deduplicated ----
echo "-- duplicate ruleset dedup"
write_cfg "
config ruleset 'dup_rs'
	option enabled '1'
	option type 'remote'
	option url 'https://example.com/dup.srs'
	option format 'binary'

config route_rule 'rule_a'
	option enabled '1'
	list ruleset 'dup_rs'
	option action 'direct'

config route_rule 'rule_b'
	option enabled '1'
	list ruleset 'dup_rs'
	option action 'block'
"
run_gen
count=$(grep -c '"tag": "dup_rs"' "$TMPDIR/out.json" || true)
[ "$count" = "1" ] \
	|| { echo "FAIL: dup_rs should appear once, got $count"; cat "$TMPDIR/out.json"; exit 1; }
echo "  PASS: duplicate rule_set deduplicated"
check "rule_a -> direct" '"outbound": "direct"' "$TMPDIR/out.json"
check "rule_a action"    '"action": "route"'    "$TMPDIR/out.json"
# action=block must NOT produce a `block` outbound reference; sing-box 1.11+
# expresses block via a rule with `action: "reject"` (no outbound).
check "rule_b -> reject" '"action": "reject"'   "$TMPDIR/out.json"
grep -q '"outbound": "block"' "$TMPDIR/out.json" \
    && { echo "FAIL: rule_b must not reference removed 'block' outbound"; exit 1; }
echo "  PASS: no 'block' outbound reference"
# And no auto-injected `block` outbound entry should be in the outbounds array.
grep -q '"type": "block"' "$TMPDIR/out.json" \
    && { echo "FAIL: 'block' outbound type must not be auto-injected"; exit 1; }
echo "  PASS: no auto-injected 'block' outbound"

echo "-- route_default action=block emits trailing {action:reject} catch-all"
write_cfg "
config inbound 'tproxy_in'
	option enabled '1'
	option protocol 'tproxy'
	option listen_port '7893'
	option hijack_dns '0'

config route_default 'route_default'
	option action 'block'
"
run_gen
grep -q '\"final\":' "$TMPDIR/out.json" \
    && { echo "FAIL: route_default action=block must not emit a 'final' key"; exit 1; }
check "catch-all reject" '\"action\": \"reject\"' "$TMPDIR/out.json"
# Catch-all must be the LAST rule (jq-free check: last occurrence of action
# in the rules array). A trailing reject without rule_set/protocol qualifies.
grep -q '"type": "block"' "$TMPDIR/out.json" \
    && { echo "FAIL: action=block must not resurrect a 'block' outbound"; exit 1; }
echo "  PASS: no 'block' outbound auto-injected"

# ---- dns.rules from dns_rule referencing ruleset ----
echo "-- dns_rule emits dns.rules entry"
write_cfg "
config dns_server 'fakeip'
	option enabled '1'
	option type 'fakeip'
	option inet4_range '198.18.0.0/15'

config ruleset 'geosite_cn'
	option enabled '1'
	option type 'remote'
	option url 'https://example.com/geosite-cn.srs'

config dns_rule 'cn_fakeip'
	option enabled '1'
	list ruleset 'geosite_cn'
	option server 'fakeip'
"
run_gen
check "dns block present" '\"dns\":'           "$TMPDIR/out.json"
check "dns.rules present" '\"rules\":'         "$TMPDIR/out.json"
check "dns rule_set cn"   '\"rule_set\":'      "$TMPDIR/out.json"
check "dns server fakeip" '"server": "fakeip"' "$TMPDIR/out.json"

echo "-- subscription urltest emits sub_urltest_url verbatim"
write_cfg "
config outbound 'subUT'
	option type 'subscription'
	option sub_url 'http://example.test/x'
	option sub_multi '1'
	option sub_selector_type 'urltest'
	option sub_urltest_url 'https://probe.example/204'
"
# Seed a sub_subUT.txt so generate.uc has something to expand.
printf '%s\n' 'vless://u@host:443?security=tls#A' > "$SANDBOX_DIR/subs/sub_subUT.txt"
run_gen
check "urltest type emitted"      '"type": "urltest"'                          "$TMPDIR/out.json"
check "urltest probe url emitted" '"url": "https://probe.example/204"'         "$TMPDIR/out.json"

echo "-- subscription urltest without sub_urltest_url omits url"
write_cfg "
config outbound 'subUT2'
	option type 'subscription'
	option sub_url 'http://example.test/x'
	option sub_multi '1'
	option sub_selector_type 'urltest'
"
printf '%s\n' 'vless://u@host:443?security=tls#A' > "$SANDBOX_DIR/subs/sub_subUT2.txt"
run_gen
grep -q '"type": "urltest"' "$TMPDIR/out.json" \
	|| { echo "FAIL: urltest not emitted (default-url case)"; exit 1; }
grep -q '"url":' "$TMPDIR/out.json" \
	&& { echo "FAIL: bare urltest should NOT emit a url field"; exit 1; }
echo "  PASS: urltest without override has no url field"

echo "-- log section absent → no log key in JSON"
write_cfg ""
run_gen
grep -q '"log":' "$TMPDIR/out.json" \
    && { echo "FAIL: log key emitted without a log section"; cat "$TMPDIR/out.json"; exit 1; }
echo "  PASS: log absent when section missing"

echo "-- log.enabled=0 → log:{disabled:true}"
write_cfg "
config log 'log'
	option enabled '0'
"
run_gen
check "log disabled" '"disabled": true' "$TMPDIR/out.json"

echo "-- log.enabled=1 level=debug output=/tmp/x.log"
write_cfg "
config log 'log'
	option enabled '1'
	option level 'debug'
	option output '/tmp/x.log'
"
run_gen
check "log level debug"  '"level": "debug"'        "$TMPDIR/out.json"
check "log output path"  '"output": "/tmp/x.log"'  "$TMPDIR/out.json"
check "log timestamp"    '"timestamp": true'       "$TMPDIR/out.json"

echo "-- log.enabled=1 without output omits the field"
write_cfg "
config log 'log'
	option enabled '1'
	option level 'info'
"
run_gen
check "log level info" '"level": "info"' "$TMPDIR/out.json"
awk '/"log":/,/}/' "$TMPDIR/out.json" | grep -q '"output":' \
    && { echo "FAIL: empty output should not be emitted"; cat "$TMPDIR/out.json"; exit 1; }
echo "  PASS: empty output omitted"

echo "-- cache.enabled=0 → no experimental block"
write_cfg "
config cache 'cache'
	option enabled '0'
"
run_gen
grep -q '"experimental":' "$TMPDIR/out.json" \
    && { echo "FAIL: experimental emitted with cache disabled"; exit 1; }
echo "  PASS: cache disabled → no experimental"

echo "-- cache.enabled=1 with fakeip dns_server and store_fakeip"
write_cfg "
config dns_server 'fakeip'
	option enabled '1'
	option type 'fakeip'
	option inet4_range '198.18.0.0/15'

config cache 'cache'
	option enabled '1'
	option store_fakeip '1'
	option storage 'custom'
	option path '/tmp/test-cache.db'
"
run_gen
check "experimental block" '"experimental":'              "$TMPDIR/out.json"
check "cache_file"         '"cache_file":'                "$TMPDIR/out.json"
check "cache enabled"      '"enabled": true'              "$TMPDIR/out.json"
check "cache path"         '"path": "/tmp/test-cache.db"' "$TMPDIR/out.json"
check "store_fakeip true"  '"store_fakeip": true'         "$TMPDIR/out.json"

echo "-- store_fakeip suppressed when fakeip dns_server disabled"
write_cfg "
config dns_server 'fakeip'
	option enabled '0'
	option type 'fakeip'

config cache 'cache'
	option enabled '1'
	option store_fakeip '1'
"
run_gen
awk '/"cache_file":/,/}/' "$TMPDIR/out.json" | grep -q '"store_fakeip":' \
    && { echo "FAIL: store_fakeip emitted without fakeip"; cat "$TMPDIR/out.json"; exit 1; }
echo "  PASS: store_fakeip suppressed when fakeip disabled"

echo "-- cache.path defaults when empty"
write_cfg "
config cache 'cache'
	option enabled '1'
"
run_gen
check "default cache path" '"path": "/tmp/singbox-ui-cache.db"' "$TMPDIR/out.json"

echo "-- route.default_domain_resolver auto-picks first non-fakeip dns_server"
write_cfg "
config dns_server 'fakeip'
	option enabled '1'
	option type 'fakeip'
	option inet4_range '198.18.0.0/15'

config dns_server 'upstream'
	option enabled '1'
	option type 'udp'
	option server '1.1.1.1'

config route_default 'route_default'
	option action 'direct'
"
run_gen
check "route block"          '\"route\":'                              "$TMPDIR/out.json"
check "default resolver key" '\"default_domain_resolver\":'            "$TMPDIR/out.json"
check "auto-picked server"   '\"server\": \"upstream\"'                "$TMPDIR/out.json"

echo "-- dns.default_resolver UCI override wins over auto-pick"
write_cfg "
config dns_server 'fakeip'
	option enabled '1'
	option type 'fakeip'
	option inet4_range '198.18.0.0/15'

config dns_server 'upstream'
	option enabled '1'
	option type 'udp'
	option server '1.1.1.1'

config dns_server 'override_me'
	option enabled '1'
	option type 'udp'
	option server '9.9.9.9'

config dns 'dns'
	option default_resolver 'override_me'

config route_default 'route_default'
	option action 'direct'
"
run_gen
check "override resolver"    '\"server\": \"override_me\"'             "$TMPDIR/out.json"

echo "-- no route block → no default_domain_resolver"
write_cfg "
config dns_server 'upstream'
	option enabled '1'
	option type 'udp'
	option server '1.1.1.1'
"
run_gen
grep -q '"default_domain_resolver"' "$TMPDIR/out.json" \
    && { echo "FAIL: default_domain_resolver must not appear without a route block"; exit 1; }
echo "  PASS: no default_domain_resolver when route block absent"

echo "-- dns_server detour='direct' is scrubbed when 'direct' is auto-injected (empty)"
# sing-box 1.12 fatally rejects a DNS detour pointing at an auto-injected empty
# direct outbound. generate.uc must strip that detour so the daemon comes up.
write_cfg "
config dns_server 'out_dns'
	option enabled '1'
	option type 'https'
	option server 'dns.google'
	option server_port '443'
	option path '/dns-query'
	option detour 'direct'

config dns 'dns'
	option final 'out_dns'
"
run_gen
check "dns servers"  '"servers":'           "$TMPDIR/out.json"
check "dns tag"      '"tag": "out_dns"'     "$TMPDIR/out.json"
check "dns server"   '"server": "dns.google"' "$TMPDIR/out.json"
check "dns path"     '"path": "/dns-query"' "$TMPDIR/out.json"
grep -q '"detour":' "$TMPDIR/out.json" \
    && { echo "FAIL: dns detour to implicit direct must be scrubbed"; exit 1; }
echo "  PASS: detour to implicit empty direct dropped"
check "dns final"    '"final": "out_dns"'   "$TMPDIR/out.json"

echo "-- dns_server detour='direct' preserved when a real 'direct' outbound exists"
write_cfg "
config outbound 'direct'
	option enabled '1'
	option type 'interface'
	option interface 'eth0'

config dns_server 'out_dns'
	option enabled '1'
	option type 'https'
	option server '1.1.1.1'
	option detour 'direct'
"
run_gen
check "dns detour kept" '"detour": "direct"' "$TMPDIR/out.json"

echo "-- dns_server with detour to a named outbound"
write_cfg "
config outbound 'my_vless'
	option enabled '1'
	option type 'url'
	option proxy_url 'vless://uuid@host:443?security=tls'

config dns_server 'out_dns'
	option enabled '1'
	option type 'https'
	option server '1.1.1.1'
	option server_port '443'
	option path '/dns-query'
	option detour 'my_vless'
"
run_gen
check "dns https server" '"server": "1.1.1.1"'  "$TMPDIR/out.json"
check "dns detour out"   '"detour": "my_vless"' "$TMPDIR/out.json"

echo "-- hijack_dns=0 → no hijack rule"
write_cfg "
config inbound 'tproxy_in'
	option enabled '1'
	option protocol 'tproxy'
	option listen_port '7893'
	option hijack_dns '0'
"
run_gen
grep -q '"action": "hijack-dns"' "$TMPDIR/out.json" \
    && { echo "FAIL: hijack-dns rule emitted with flag off"; exit 1; }
echo "  PASS: no hijack rule when flag off"

echo "-- hijack_dns=1 → first route.rule is {protocol:dns, action:hijack-dns}"
write_cfg "
config inbound 'tproxy_in'
	option enabled '1'
	option protocol 'tproxy'
	option listen_port '7893'
	option hijack_dns '1'

config outbound 'p'
	option type 'interface'
	option interface 'eth0'

config ruleset 'cn'
	option enabled '1'
	option type 'remote'
	option url 'https://example.com/cn.srs'

config route_rule 'r1'
	option enabled '1'
	list ruleset 'cn'
	option action 'direct'
"
run_gen
check "hijack protocol dns"   '"protocol": "dns"'        "$TMPDIR/out.json"
check "hijack action"         '"action": "hijack-dns"'   "$TMPDIR/out.json"
# Hijack must be FIRST. Find both lines and compare line numbers.
# Use the rule-level "rule_set": (indented inside a rule object) not the top-level route rule_set array.
hijack_ln=$(grep -n '"action": "hijack-dns"' "$TMPDIR/out.json" | head -n1 | cut -d: -f1)
other_ln=$(grep -n '"outbound": "direct"' "$TMPDIR/out.json" | head -n1 | cut -d: -f1)
if [ -z "$hijack_ln" ] || [ -z "$other_ln" ] || [ "$hijack_ln" -ge "$other_ln" ]; then
    echo "FAIL: hijack rule must precede rule_set rules (hijack@$hijack_ln, other@$other_ln)"
    cat "$TMPDIR/out.json"
    exit 1
fi
echo "  PASS: hijack rule is first"

echo "-- hijack_dns=1 on an enabled tproxy inbound emits hijack rule"
write_cfg "
config inbound 'tproxy_in'
	option enabled '1'
	option protocol 'tproxy'
	option listen_port '7893'
	option hijack_dns '1'
"
run_gen
check "hijack rule still present" '"action": "hijack-dns"' "$TMPDIR/out.json"

echo "-- direct inbound with dns_listener=1 auto-adds hijack-dns route rule"
write_cfg "
config inbound 'dns_in'
	option enabled '1'
	option protocol 'direct'
	option listen '127.0.0.53'
	option listen_port '53'
	option network 'udp'
	option dns_listener '1'
"
run_gen
check "hijack-dns rule action"   '"action": "hijack-dns"'  "$TMPDIR/out.json"
check "hijack-dns rule inbound"  '"inbound": "dns_in"'     "$TMPDIR/out.json"

echo "-- clash_api.enabled=1 emits experimental.clash_api alongside cache_file"
write_cfg "
config clash_api 'clash_api'
	option enabled '1'
	option listen '127.0.0.1'
	option port '9090'
	option secret 'sekret'

config cache 'cache'
	option enabled '1'
"
run_gen
check "experimental block"   '"experimental":'                          "$TMPDIR/out.json"
check "clash_api controller" '"external_controller": "127.0.0.1:9090"' "$TMPDIR/out.json"
check "clash_api secret"     '"secret": "sekret"'                       "$TMPDIR/out.json"
check "cache_file kept"      '"cache_file":'                            "$TMPDIR/out.json"

echo "-- clash_api disabled → no clash_api key"
write_cfg "
config clash_api 'clash_api'
	option enabled '0'
"
run_gen
grep -q '"clash_api":' "$TMPDIR/out.json" \
	&& { echo "FAIL: clash_api emitted while disabled"; exit 1; }
echo "  PASS: clash_api absent when disabled"

# Phase C2 final sweep: after the full battery of generate runs, the sandbox
# dir must contain no orphan tmpfiles. A single leaked tmpfile from any
# successful or failed scenario above would fail this.
orphans_final=$(find "$SANDBOX_DIR" -name "$(basename "$SANDBOX_CONFIG").tmp.*" 2>/dev/null | wc -l)
[ "$orphans_final" -eq 0 ] || { echo "FAIL: $orphans_final orphan tmpfiles after full run"; find "$SANDBOX_DIR" -name "$(basename "$SANDBOX_CONFIG").tmp.*"; exit 1; }
echo "  PASS: no orphan tmpfiles after full test run"

# Phase C2.3.2: final defensive layer. The substring assertions above
# can miss "shape looks right but daemon rejects it" bugs (canonical
# example: the DNS-detour-to-implicit-direct startup crash).
#
# Most of the scenarios above use synthetic test fixtures (short UUIDs,
# minimal-but-incomplete configs) that exercise generator emission
# without producing a daemon-valid result. So instead of bolting
# sb_check onto each, we build one explicitly-complete config that
# exercises the full pipeline — DNS, route, ruleset, real-shaped UUID
# proxy outbound, tproxy inbound with hijack — and hand THAT to
# sing-box check. This catches the "shape right, daemon rejects" class
# of bugs at a known-complete checkpoint.
echo "-- sing-box check end-to-end on a complete config"
# Mirrors the shape of the shipped default (test_defaults.sh) so the
# config is known-daemon-valid: non-fakeip server listed first, dns.final
# pins the upstream, real-shaped vless UUID, complete tproxy + ruleset
# wiring. Any future generator regression that breaks this end-to-end
# shape will be caught by sing-box check here, even if the substring
# assertions above still pass.
write_cfg "
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

config outbound 'my_vless'
	option enabled '1'
	option type 'url'
	option proxy_url 'vless://aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee@vless.example.com:443?security=tls&sni=vless.example.com'

config ruleset 'geosite_cn'
	option enabled '1'
	option type 'remote'
	option url 'https://example.com/geosite-cn.srs'
	option format 'binary'

config route_rule 'rule_cn'
	option enabled '1'
	list ruleset 'geosite_cn'
	option action 'outbound'
	option outbound 'my_vless'

config route_default 'route_default'
	option final 'my_vless'
"
run_gen
sb_check "complete config (dns+fakeip+tproxy+vless+route)" "$TMPDIR/out.json"

echo "OK"
