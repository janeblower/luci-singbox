#!/bin/sh
# tests/test_outbound_constructor.sh
# Drives generate.uc with typed outbounds (type=vless/vmess/etc.) and asserts the
# emitted outbounds[]. Mirrors test_generate.sh's harness.
set -e

if command -v ucode >/dev/null 2>&1; then
	UCODE_BIN=ucode
	UCODE_LIB_FLAGS="-L ${UCODE_APP_LIB_DIR:-$PWD/luci-singbox-ui/root/usr/share/singbox-ui/lib}"
elif [ -x "${UCODE_BIN:-}" ] && [ -d "${UCODE_STUB_DIR:-}" ]; then
	UCODE_LIB_FLAGS="-L $UCODE_STUB_DIR -L ${UCODE_APP_LIB_DIR:-$PWD/luci-singbox-ui/root/usr/share/singbox-ui/lib}"
	[ -n "${UCODE_LIB_DIR:-}" ] && UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L $UCODE_LIB_DIR"
else
	echo "SKIP: ucode not available"; exit 0
fi

GENERATE_UC=luci-singbox-ui/root/usr/share/singbox-ui/generate.uc
TMPDIR=$(mktemp -d); trap 'rm -rf "$TMPDIR"' EXIT
SANDBOX_DIR="$TMPDIR/sandbox"; mkdir -p "$SANDBOX_DIR/subs"
SANDBOX_CONFIG="$SANDBOX_DIR/singbox-ui.json"
check() { grep -q "$2" "$TMPDIR/out.json" || { echo "FAIL: $1 — '$2'"; cat "$TMPDIR/out.json"; exit 1; }; echo "  PASS: $1"; }
nocheck() { grep -q "$2" "$TMPDIR/out.json" && { echo "FAIL: $1 — '$2' present"; cat "$TMPDIR/out.json"; exit 1; }; echo "  PASS: $1"; }
write_cfg() { printf '%s\n' "$1" > "$TMPDIR/singbox-ui"; }
run_gen() {
	# shellcheck disable=SC2086
	UCI_CONFIG_DIR="$TMPDIR" SINGBOX_TMPDIR="$SANDBOX_DIR/subs" SINGBOX_CONFIG="$SANDBOX_CONFIG" \
	"$UCODE_BIN" $UCODE_LIB_FLAGS "$GENERATE_UC" >"$TMPDIR/gen.stderr" 2>&1 && cp "$SANDBOX_CONFIG" "$TMPDIR/out.json"
}

echo "-- vless with reality + grpc"
write_cfg "
config outbound 'vl'
	option enabled '1'
	option type 'vless'
	option server 'vless.example.com'
	option server_port '443'
	option server_uuid 'uuid-aaaa'
	option vless_flow 'xtls-rprx-vision'
	option tls_enabled '1'
	option reality_enabled '1'
	option tls_server_name 'www.microsoft.com'
	option utls_enabled '1'
	option utls_fingerprint 'chrome'
	option reality_public_key 'PUBKEY'
	option reality_short_id 'ab12'
	option transport_type 'grpc'
	option transport_service_name 'gun'
"
run_gen
check "vless type"        '"type": "vless"'
check "vless tag"         '"tag": "vl"'
check "vless server"      '"server": "vless.example.com"'
check "vless port"        '"server_port": 443'
check "vless uuid"        '"uuid": "uuid-aaaa"'
check "vless flow"        '"flow": "xtls-rprx-vision"'
check "vless reality pub" '"public_key": "PUBKEY"'
check "vless utls"        '"fingerprint": "chrome"'
check "vless grpc"        '"service_name": "gun"'

echo "-- trojan"
write_cfg "
config outbound 'tj'
	option enabled '1'
	option type 'trojan'
	option server 't.example.com'
	option server_port '443'
	option server_password 'tj-pw'
	option tls_enabled '1'
"
run_gen
check "trojan type"     '"type": "trojan"'
check "trojan password" '"password": "tj-pw"'
check "trojan tls"      '"enabled": true'

echo "-- hysteria2 forces tls + obfs"
write_cfg "
config outbound 'hy'
	option enabled '1'
	option type 'hysteria2'
	option server 'h.example.com'
	option server_port '8443'
	option server_password 'hy-pw'
	option obfs_type 'salamander'
	option obfs_password 'obfs'
	option up_mbps '50'
	option down_mbps '100'
"
run_gen
check "hy2 type"     '"type": "hysteria2"'
check "hy2 password" '"password": "hy-pw"'
check "hy2 obfs"     '"type": "salamander"'
check "hy2 up"       '"up_mbps": 50'
check "hy2 tls"      '"enabled": true'

echo "-- shadowsocks"
write_cfg "
config outbound 'ss'
	option enabled '1'
	option type 'shadowsocks'
	option server 's.example.com'
	option server_port '8388'
	option shadowsocks_method 'aes-256-gcm'
	option server_password 'ss-pw'
"
run_gen
check "ss type"     '"type": "shadowsocks"'
check "ss method"   '"method": "aes-256-gcm"'
check "ss password" '"password": "ss-pw"'

echo "-- extra_json is no longer honoured (field deprecated)"
write_cfg "
config outbound 'ex'
	option enabled '1'
	option type 'trojan'
	option server 'e.example.com'
	option server_port '443'
	option server_password 'p'
	option extra_json '{\"multiplex\":{\"enabled\":true}}'
"
run_gen
nocheck "extra not merged" '"multiplex":'

echo "-- section with empty type is skipped (unmigrated)"
write_cfg "
config outbound 'notype'
	option enabled '1'
"
run_gen || true
nocheck "notype skipped" '"tag": "notype"'

echo "-- vless outbound with multiplex + utls"
write_cfg "
config outbound 'vl'
	option enabled '1'
	option type 'vless'
	option server 'a.b'
	option server_port '443'
	option server_uuid 'uu'
	option tls_enabled '1'
	option tls_server_name 'a.b'
	option utls_enabled '1'
	option utls_fingerprint 'chrome'
	option multiplex_enabled '1'
	option multiplex_protocol 'smux'
	option multiplex_max_connections '4'
"
run_gen
check "outbound utls"         '"fingerprint": "chrome"'
check "outbound mux smux"     '"protocol": "smux"'
check "outbound mux max"      '"max_connections": 4'

echo "-- hysteria2 outbound with masquerade"
write_cfg "
config outbound 'hy'
	option enabled '1'
	option type 'hysteria2'
	option server 'h.b'
	option server_port '8443'
	option server_password 'p'
	option up_mbps '100'
	option down_mbps '50'
	option masquerade 'https://www.example.com'
"
run_gen
check "outbound hy2 masquerade" '"masquerade": "https://www.example.com"'

echo "-- vless outbound with xhttp transport"
write_cfg "
config outbound 'vx'
	option enabled '1'
	option type 'vless'
	option server 'a.b'
	option server_port '443'
	option server_uuid 'uu'
	option transport_type 'xhttp'
	option transport_path '/x'
	option transport_xhttp_mode 'stream-up'
"
run_gen
check "outbound vless xhttp"      '"type": "xhttp"'
check "outbound vless xhttp mode" '"mode": "stream-up"'

echo "-- hysteria2 outbound with brutal_debug + network restriction"
write_cfg "
config outbound 'hyb'
	option enabled '1'
	option type 'hysteria2'
	option server 'h.b'
	option server_port '8443'
	option server_password 'p'
	option brutal_debug '1'
	option network 'udp'
"
run_gen
check "outbound hy2 brutal_debug" '"brutal_debug": true'
check "outbound hy2 network=udp"  '"network": "udp"'

echo "-- hysteria2 outbound rejects unknown network values"
write_cfg "
config outbound 'hybad'
	option enabled '1'
	option type 'hysteria2'
	option server 'h.b'
	option server_port '8443'
	option server_password 'p'
	option network 'sctp'
"
run_gen
nocheck "no bogus network" '"network": "sctp"'

echo "-- vless outbound with ECH (client-side: config + config_path) + fragment"
write_cfg "
config outbound 'vech'
	option enabled '1'
	option type 'vless'
	option server 'ech.example.com'
	option server_port '443'
	option server_uuid 'uu-ech'
	option tls_enabled '1'
	option tls_server_name 'ech.example.com'
	option tls_ech_enabled '1'
	list   tls_ech_config '-----BEGIN ECH CONFIG-----'
	list   tls_ech_config 'BASE64DATA'
	list   tls_ech_config '-----END ECH CONFIG-----'
	option tls_ech_config_path '/etc/sing-box/ech.pem'
	option tls_fragment '1'
	option tls_fragment_fallback_delay '750ms'
	option tls_record_fragment '1'
"
run_gen
check  "ech client enabled"      '"ech":'
check  "ech.config array"        '"config": \['
check  "ech.config first line"   '"-----BEGIN ECH CONFIG-----"'
check  "ech.config_path"         '"config_path": "/etc/sing-box/ech.pem"'
check  "fragment true"            '"fragment": true'
check  "fragment_fallback_delay" '"fragment_fallback_delay": "750ms"'
check  "record_fragment true"    '"record_fragment": true'
nocheck "no pq schemes (deprecated)" 'pq_signature_schemes_enabled'

echo "-- vless outbound without tls_ech / fragment omits all of them"
write_cfg "
config outbound 'vplain'
	option enabled '1'
	option type 'vless'
	option server 'a.b'
	option server_port '443'
	option server_uuid 'uu'
	option tls_enabled '1'
	option tls_server_name 'a.b'
"
run_gen
nocheck "no ech when unset"      '"ech":'
nocheck "no fragment when unset" '"fragment":'
nocheck "no record_fragment unset" '"record_fragment":'

# D1.2: shadowsocks descriptor migration parity guard — byte-equal golden assertion.
# Must pass both before (legacy) and after (descriptor) the migration.
echo "-- shadowsocks descriptor parity (D1.2 golden)"
golden='{ "type": "shadowsocks", "tag": "ss1", "server": "example.com", "server_port": 8388, "method": "aes-128-gcm", "password": "pw" }'
actual=$(
	# shellcheck disable=SC2086
	"$UCODE_BIN" $UCODE_LIB_FLAGS -e '
let ob = require("outbound");
let s = { ".name":"ss1", "server":"example.com", "server_port":"8388",
          "server_password":"pw", "shadowsocks_method":"aes-128-gcm" };
printf("%J", ob.build_constructor_for(s, "shadowsocks"));
'
)
if [ "$actual" = "$golden" ]; then
	echo "  PASS: shadowsocks parity"
else
	echo "FAIL: shadowsocks parity"
	echo "  expected: $golden"
	echo "  actual:   $actual"
	exit 1
fi

# D1.1: trojan descriptor migration parity guard — byte-equal golden assertion.
# Must pass both before (legacy) and after (descriptor) the migration.
echo "-- trojan descriptor parity (D1.1 golden)"
golden='{ "type": "trojan", "tag": "t1", "server": "example.com", "server_port": 443, "password": "pw", "tls": { "enabled": true, "server_name": "example.com" } }'
actual=$(
	# shellcheck disable=SC2086
	"$UCODE_BIN" $UCODE_LIB_FLAGS -e '
let ob = require("outbound");
let s = { ".name":"t1", "server":"example.com", "server_port":"443",
          "server_password":"pw", "tls_enabled":"1", "tls_server_name":"example.com" };
printf("%J", ob.build_constructor_for(s, "trojan"));
'
)
if [ "$actual" = "$golden" ]; then
	echo "  PASS: trojan parity"
else
	echo "FAIL: trojan parity"
	echo "  expected: $golden"
	echo "  actual:   $actual"
	exit 1
fi

# D1.3: vless descriptor migration parity guard — byte-equal golden assertion.
# Updated in E2: VLESS now uses new DSL (tls_enabled instead of security=tls).
echo "-- vless descriptor parity (D1.3 golden)"
golden='{ "type": "vless", "tag": "vl1", "server": "vless.example.com", "server_port": 443, "uuid": "550e8400-e29b-41d4-a716-446655440000", "flow": "xtls-rprx-vision", "tls": { "enabled": true, "server_name": "vless.example.com" } }'
actual=$(
	# shellcheck disable=SC2086
	"$UCODE_BIN" $UCODE_LIB_FLAGS -e '
let ob = require("outbound");
let s = { ".name":"vl1", "server":"vless.example.com", "server_port":"443",
          "server_uuid":"550e8400-e29b-41d4-a716-446655440000",
          "vless_flow":"xtls-rprx-vision",
          "tls_enabled":"1", "tls_server_name":"vless.example.com" };
printf("%J", ob.build_constructor_for(s, "vless"));
'
)
if [ "$actual" = "$golden" ]; then
	echo "  PASS: vless parity"
else
	echo "FAIL: vless parity"
	echo "  expected: $golden"
	echo "  actual:   $actual"
	exit 1
fi

# D1.5: hysteria2 descriptor migration parity guard — byte-equal golden assertion.
# Must pass both before (legacy) and after (descriptor) the migration.
echo "-- hysteria2 descriptor parity (D1.5 golden)"
golden_hy2='{ "type": "hysteria2", "tag": "hy2full", "server": "hy2.example.com", "server_port": 8443, "password": "secret-pass", "obfs": { "type": "salamander", "password": "obfs-pw" }, "up_mbps": 100, "down_mbps": 50, "masquerade": "https://www.example.com", "brutal_debug": true, "network": "tcp", "tls": { "enabled": true, "server_name": "hy2.example.com" } }'
actual_hy2=$(
	# shellcheck disable=SC2086
	"$UCODE_BIN" $UCODE_LIB_FLAGS -e '
let ob = require("outbound");
let s = { ".name":"hy2full", "server":"hy2.example.com", "server_port":"8443",
          "server_password":"secret-pass",
          "obfs_type":"salamander", "obfs_password":"obfs-pw",
          "up_mbps":"100", "down_mbps":"50",
          "masquerade":"https://www.example.com",
          "brutal_debug":"1", "network":"tcp",
          "security":"tls", "tls_server_name":"hy2.example.com" };
printf("%J", ob.build_constructor_for(s, "hysteria2"));
'
)
if [ "$actual_hy2" = "$golden_hy2" ]; then
	echo "  PASS: hysteria2 parity (full)"
else
	echo "FAIL: hysteria2 parity (full)"
	echo "  expected: $golden_hy2"
	echo "  actual:   $actual_hy2"
	exit 1
fi

# D1.5 minimal variant: confirms all conditional branches skip cleanly.
echo "-- hysteria2 descriptor parity minimal (D1.5 golden)"
golden_hy2_min='{ "type": "hysteria2", "tag": "hy2min", "server": "hy2.example.com", "server_port": 8443, "password": "secret-pass", "tls": { "enabled": true, "server_name": "hy2.example.com" } }'
actual_hy2_min=$(
	# shellcheck disable=SC2086
	"$UCODE_BIN" $UCODE_LIB_FLAGS -e '
let ob = require("outbound");
let s = { ".name":"hy2min", "server":"hy2.example.com", "server_port":"8443",
          "server_password":"secret-pass",
          "security":"tls", "tls_server_name":"hy2.example.com" };
printf("%J", ob.build_constructor_for(s, "hysteria2"));
'
)
if [ "$actual_hy2_min" = "$golden_hy2_min" ]; then
	echo "  PASS: hysteria2 parity (minimal)"
else
	echo "FAIL: hysteria2 parity (minimal)"
	echo "  expected: $golden_hy2_min"
	echo "  actual:   $actual_hy2_min"
	exit 1
fi

echo "OK"
