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
	UCODE_LIB_FLAGS="-L ${UCODE_APP_LIB_DIR:-$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/lib}"
elif [ -x "${UCODE_BIN:-}" ] && [ -d "${UCODE_STUB_DIR:-}" ]; then
	UCODE_LIB_FLAGS="-L $UCODE_STUB_DIR -L ${UCODE_APP_LIB_DIR:-$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/lib}"
	[ -n "${UCODE_LIB_DIR:-}" ] && UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L $UCODE_LIB_DIR"
else
	echo "SKIP: ucode not available (set UCODE_BIN + UCODE_STUB_DIR [+ UCODE_LIB_DIR] to run locally)"
	exit 0
fi

GENERATE_UC=luci-app-singbox-ui/root/usr/share/singbox-ui/generate.uc
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

check() {
	desc="$1"; pattern="$2"; file="$3"
	grep -q "$pattern" "$file" \
		|| { echo "FAIL: $desc — '$pattern' not found in $file"; cat "$file"; exit 1; }
	echo "  PASS: $desc"
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
	"$UCODE_BIN" $UCODE_LIB_FLAGS "$GENERATE_UC" >/dev/null \
		&& cp "$SANDBOX_CONFIG" "$TMPDIR/out.json"
}

# ---- fakeip + tproxy ----
echo "-- fakeip and tproxy inbound"
write_cfg "
config fakeip 'fakeip'
	option enabled '1'
	option inet4_range '198.18.0.0/15'
	option inet6_range 'fc00::/18'

config tproxy 'tproxy'
	option enabled '1'
	option port '7893'
"
run_gen
check "fakeip enabled"    '"enabled": true'              "$TMPDIR/out.json"
check "inet4_range str"   '"inet4_range": "198.18.0.0/15"' "$TMPDIR/out.json"
check "inet6_range str"   '"inet6_range": "fc00::/18"'     "$TMPDIR/out.json"
check "tproxy inbound"    '"type": "tproxy"'              "$TMPDIR/out.json"
check "listen_port 7893"  '"listen_port": 7893'           "$TMPDIR/out.json"
# Negative: must NOT emit as an array (sing-box 1.12+ rejects arrays here)
grep -q '"inet4_range":\s*\[' "$TMPDIR/out.json" \
	&& { echo "FAIL: inet4_range must be a string, not an array"; cat "$TMPDIR/out.json"; exit 1; }
echo "  PASS: inet4_range is not an array"

# ---- proxy via interface ----
echo "-- proxy via interface"
write_cfg "
config outbound 'via_wg0'
	option proxy_type 'interface'
	option interface 'wg0'
"
run_gen
check "interface proxy tag"  '"tag": "via_wg0"'         "$TMPDIR/out.json"
check "bind_interface"       '"bind_interface": "wg0"'  "$TMPDIR/out.json"

# ---- vless URL ----
echo "-- vless:// URL"
write_cfg "
config outbound 'my_vless'
	option proxy_type 'url'
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
	option proxy_type 'url'
	option proxy_url 'hy2://mypassword@vpn.example.com:8443?sni=vpn.example.com'
"
run_gen
check "hy2 type"     '"type": "hysteria2"'         "$TMPDIR/out.json"
check "hy2 password" '"password": "mypassword"'    "$TMPDIR/out.json"
check "hy2 server"   '"server": "vpn.example.com"' "$TMPDIR/out.json"

# ---- json outbound ----
echo "-- proxy_type=json"
write_cfg "
config outbound 'my_json_out'
	option enabled '1'
	option proxy_type 'json'
	option proxy_json '{\"type\":\"vmess\",\"server\":\"json.example.com\",\"server_port\":8443,\"uuid\":\"abc-123\"}'
"
run_gen
check "json tag"    '"tag": "my_json_out"'         "$TMPDIR/out.json"
check "json type"   '"type": "vmess"'              "$TMPDIR/out.json"
check "json server" '"server": "json.example.com"' "$TMPDIR/out.json"
check "json port"   '"server_port": 8443'          "$TMPDIR/out.json"
check "json uuid"   '"uuid": "abc-123"'            "$TMPDIR/out.json"

# ---- outbound without proxy_type is skipped (no longer a valid outbound) ----
echo "-- outbound without proxy_type is skipped"
write_cfg "
config outbound 'leftover_direct_out'
	option action 'direct'
"
run_gen
grep -q '"tag": "leftover_direct_out"' "$TMPDIR/out.json" \
	&& { echo "FAIL: outbound without proxy_type must be skipped"; cat "$TMPDIR/out.json"; exit 1; }
echo "  PASS: outbound without proxy_type is skipped"

# ---- subscription outbound ----
echo "-- proxy_type=subscription"
printf 'vless://sub-uuid-9999@sub.example.com:443?security=tls&sni=sub.example.com\n' \
	> "$SANDBOX_DIR/subs/sub_my_sub_out.txt"
write_cfg "
config outbound 'my_sub_out'
	option enabled '1'
	option proxy_type 'subscription'
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
	option proxy_type 'url'
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
check "rule_b -> block"  '"outbound": "block"'  "$TMPDIR/out.json"

# ---- dns.rules from ruleset.dns_fakeip ----
echo "-- dns_fakeip emits dns.rules entry"
write_cfg "
config fakeip 'fakeip'
	option enabled '1'
	option inet4_range '198.18.0.0/15'
	option inet6_range 'fc00::/18'

config ruleset 'geosite_cn'
	option enabled '1'
	option type 'remote'
	option url 'https://example.com/geosite-cn.srs'
	option format 'binary'
	option dns_fakeip '1'
	option dns_fakeip_tag 'fakeip'

config route_rule 'cn_direct'
	option enabled '1'
	list ruleset 'geosite_cn'
	option action 'direct'
"
run_gen
check "dns block present" '\"dns\":'           "$TMPDIR/out.json"
check "dns.rules present" '\"rules\":'         "$TMPDIR/out.json"
check "dns rule_set cn"   '\"rule_set\":'      "$TMPDIR/out.json"
check "dns server fakeip" '"server": "fakeip"' "$TMPDIR/out.json"

# ---- dns.rules omitted when no dns_fakeip ruleset ----
echo "-- no dns.rules without dns_fakeip"
write_cfg "
config fakeip 'fakeip'
	option enabled '1'
	option inet4_range '198.18.0.0/15'

config ruleset 'plain'
	option enabled '1'
	option type 'remote'
	option url 'https://example.com/plain.srs'
	option format 'binary'

config route_rule 'plain_rule'
	option enabled '1'
	list ruleset 'plain'
	option action 'direct'
"
run_gen
# The dns object should exist but have no rules array inside it
awk '/"dns":/,/^    }/' "$TMPDIR/out.json" | grep -q '"rules":' \
	&& { echo "FAIL: dns.rules emitted without any dns_fakeip=1 ruleset"; cat "$TMPDIR/out.json"; exit 1; }
echo "  PASS: dns.rules omitted when no dns_fakeip ruleset"

echo "-- subscription urltest emits sub_urltest_url verbatim"
write_cfg "
config outbound 'subUT'
	option proxy_type 'subscription'
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
	option proxy_type 'subscription'
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
write_cfg "
config fakeip 'fakeip'
	option enabled '0'
"
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

echo "-- cache.enabled=1 with fakeip and store_fakeip"
write_cfg "
config fakeip 'fakeip'
	option enabled '1'
	option inet4_range '198.18.0.0/15'

config cache 'cache'
	option enabled '1'
	option store_fakeip '1'
	option path '/tmp/test-cache.db'
"
run_gen
check "experimental block" '"experimental":'              "$TMPDIR/out.json"
check "cache_file"         '"cache_file":'                "$TMPDIR/out.json"
check "cache enabled"      '"enabled": true'              "$TMPDIR/out.json"
check "cache path"         '"path": "/tmp/test-cache.db"' "$TMPDIR/out.json"
check "store_fakeip true"  '"store_fakeip": true'         "$TMPDIR/out.json"

echo "-- store_fakeip suppressed when fakeip disabled"
write_cfg "
config fakeip 'fakeip'
	option enabled '0'

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

echo "OK"
