#!/bin/sh
# tests/test_dns_uc.sh — generate.uc DNS block from dns_server/dns_rule/dns.
set -e
if command -v ucode >/dev/null 2>&1; then
	UCODE_BIN=ucode; UCODE_LIB_FLAGS="-L ${UCODE_APP_LIB_DIR:-$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/lib}"
elif [ -x "${UCODE_BIN:-}" ] && [ -d "${UCODE_STUB_DIR:-}" ]; then
	UCODE_LIB_FLAGS="-L $UCODE_STUB_DIR -L ${UCODE_APP_LIB_DIR:-$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/lib}"
	[ -n "${UCODE_LIB_DIR:-}" ] && UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L $UCODE_LIB_DIR"
else echo "SKIP: ucode not available"; exit 0; fi
GENERATE_UC=luci-app-singbox-ui/root/usr/share/singbox-ui/generate.uc
TMPDIR=$(mktemp -d); trap 'rm -rf "$TMPDIR"' EXIT
SANDBOX_DIR="$TMPDIR/sandbox"; mkdir -p "$SANDBOX_DIR/subs"; SANDBOX_CONFIG="$SANDBOX_DIR/singbox-ui.json"
check() { grep -q "$2" "$TMPDIR/out.json" || { echo "FAIL: $1 — '$2'"; cat "$TMPDIR/out.json"; exit 1; }; echo "  PASS: $1"; }
nocheck(){ grep -q "$2" "$TMPDIR/out.json" && { echo "FAIL: $1 — '$2' present"; cat "$TMPDIR/out.json"; exit 1; }; echo "  PASS: $1"; }
write_cfg(){ printf '%s\n' "$1" > "$TMPDIR/singbox-ui"; }
run_gen(){ # shellcheck disable=SC2086
	UCI_CONFIG_DIR="$TMPDIR" SINGBOX_TMPDIR="$SANDBOX_DIR/subs" SINGBOX_CONFIG="$SANDBOX_CONFIG" \
	"$UCODE_BIN" $UCODE_LIB_FLAGS "$GENERATE_UC" >"$TMPDIR/gen.stderr" 2>&1 && cp "$SANDBOX_CONFIG" "$TMPDIR/out.json"; }

echo "-- typed servers (https/udp/fakeip) + final/strategy"
# A user-defined 'direct' outbound keeps the dns_server detour intact;
# without it generate.uc would scrub the reference (see test_generate.sh).
write_cfg "
config outbound 'direct'
	option enabled '1'
	option proxy_type 'interface'
	option interface 'eth0'

config dns_server 'google'
	option enabled '1'
	option type 'https'
	option server 'dns.google'
	option server_port '443'
	option path '/dns-query'
	option detour 'direct'

config dns_server 'local'
	option enabled '1'
	option type 'udp'
	option server '192.168.1.1'

config dns_server 'fakeip'
	option enabled '1'
	option type 'fakeip'
	option inet4_range '198.18.0.0/15'
	option inet6_range 'fc00::/18'

config dns 'dns'
	option final 'google'
	option strategy 'prefer_ipv4'
"
run_gen
check "dns block"       '"dns":'
check "https type"      '"type": "https"'
check "https server"    '"server": "dns.google"'
check "https path"      '"path": "/dns-query"'
check "https detour"    '"detour": "direct"'
check "udp type"        '"type": "udp"'
check "fakeip type"     '"type": "fakeip"'
check "fakeip v4"       '"inet4_range": "198.18.0.0/15"'
check "dns final"       '"final": "google"'
check "dns strategy"    '"strategy": "prefer_ipv4"'

echo "-- dns_rule: rule_set + domains + clash_mode"
write_cfg "
config ruleset 'ru'
	option enabled '1'
	option type 'remote'
	option url 'https://example.com/ru.srs'

config dns_server 'fakeip'
	option enabled '1'
	option type 'fakeip'
	option inet4_range '198.18.0.0/15'

config dns_rule 'r1'
	option enabled '1'
	list ruleset 'ru'
	option domain_suffix 'example.com, test.org'
	option clash_mode 'global'
	option server 'fakeip'

config dns 'dns'
	option final 'fakeip'
"
run_gen
check "dns rules"          '"rules":'
check "rule server"        '"server": "fakeip"'
check "rule rule_set"      '"rule_set":'
check "rule domain_suffix" '"example.com"'
check "rule clash_mode"    '"clash_mode": "global"'

echo "-- empty dns_rule (no matchers, no server) is dropped"
write_cfg "
config dns_server 'g'
	option enabled '1'
	option type 'udp'
	option server '1.1.1.1'

config dns_rule 'empty'
	option enabled '1'
"
run_gen
nocheck "no empty rule" '"action": "route"'

echo "-- disabled dns_server skipped"
write_cfg "
config dns_server 'off'
	option enabled '0'
	option type 'udp'
	option server '9.9.9.9'

config dns_server 'on'
	option enabled '1'
	option type 'udp'
	option server '1.1.1.1'
"
run_gen
check "enabled server" '"server": "1.1.1.1"'
nocheck "disabled server" '"server": "9.9.9.9"'

echo "-- dns.independent_cache flag becomes boolean true"
write_cfg "
config dns_server 'g'
	option enabled '1'
	option type 'udp'
	option server '1.1.1.1'

config dns 'dns'
	option independent_cache '1'
"
run_gen
check "independent_cache true" '"independent_cache": true'

echo "OK"
