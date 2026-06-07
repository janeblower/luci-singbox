#!/bin/sh
# tests/test_outbound_constructor.sh
# Drives generate.uc with typed outbounds (type=vless/vmess/etc.) and asserts the
# emitted outbounds[]. Mirrors test_generate.sh's harness.
set -e

if command -v ucode >/dev/null 2>&1; then
	UCODE_BIN=ucode
	UCODE_LIB_FLAGS="-L ${UCODE_APP_LIB_DIR:-$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/lib}"
elif [ -x "${UCODE_BIN:-}" ] && [ -d "${UCODE_STUB_DIR:-}" ]; then
	UCODE_LIB_FLAGS="-L $UCODE_STUB_DIR -L ${UCODE_APP_LIB_DIR:-$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/lib}"
	[ -n "${UCODE_LIB_DIR:-}" ] && UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L $UCODE_LIB_DIR"
else
	echo "SKIP: ucode not available"; exit 0
fi

GENERATE_UC=luci-app-singbox-ui/root/usr/share/singbox-ui/generate.uc
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
	option security 'reality'
	option tls_server_name 'www.microsoft.com'
	option utls_fingerprint 'chrome'
	option reality_public_key 'PUBKEY'
	option reality_short_id 'ab12'
	option transport 'grpc'
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

echo "-- vmess with tls + alterId + cipher"
write_cfg "
config outbound 'vm'
	option enabled '1'
	option type 'vmess'
	option server 'vm.example.com'
	option server_port '8443'
	option server_uuid 'uuid-bbbb'
	option vmess_alter_id '0'
	option vmess_security 'auto'
	option security 'tls'
	option tls_server_name 'vm.example.com'
	option tls_insecure '1'
"
run_gen
check "vmess type"     '"type": "vmess"'
check "vmess uuid"     '"uuid": "uuid-bbbb"'
check "vmess alter"    '"alter_id": 0'
check "vmess cipher"   '"security": "auto"'
check "vmess insecure" '"insecure": true'

echo "-- trojan"
write_cfg "
config outbound 'tj'
	option enabled '1'
	option type 'trojan'
	option server 't.example.com'
	option server_port '443'
	option server_password 'tj-pw'
	option security 'tls'
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
	option hysteria2_obfs_type 'salamander'
	option hysteria2_obfs_password 'obfs'
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
	option security 'tls'
	option tls_server_name 'a.b'
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
	option hysteria2_masquerade 'https://www.example.com'
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
	option transport 'xhttp'
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
	option security 'tls'
	option tls_server_name 'ech.example.com'
	option tls_ech '1'
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
	option security 'tls'
	option tls_server_name 'a.b'
"
run_gen
nocheck "no ech when unset"      '"ech":'
nocheck "no fragment when unset" '"fragment":'
nocheck "no record_fragment unset" '"record_fragment":'

echo "-- tuic outbound: congestion + heartbeat + zero_rtt + udp_relay_mode"
write_cfg "
config outbound 'tuic_basic'
	option enabled '1'
	option type 'tuic'
	option server 't.example.com'
	option server_port '443'
	option server_uuid 'uuid-tuic'
	option server_password 'pw'
	option security 'tls'
	option tls_server_name 't.example.com'
	option tuic_congestion 'bbr'
	option tuic_heartbeat '15s'
	option tuic_zero_rtt '1'
	option tuic_udp_relay_mode 'quic'
"
run_gen
check  "tuic type"            '"type": "tuic"'
check  "tuic uuid"            '"uuid": "uuid-tuic"'
check  "tuic password"        '"password": "pw"'
check  "tuic congestion"      '"congestion_control": "bbr"'
check  "tuic heartbeat"       '"heartbeat": "15s"'
check  "tuic zero_rtt"        '"zero_rtt_handshake": true'
check  "tuic udp_relay_mode"  '"udp_relay_mode": "quic"'
check  "tuic tls present"     '"tls":'

echo "-- tuic outbound: udp_over_stream takes precedence over udp_relay_mode"
write_cfg "
config outbound 'tuic_stream'
	option enabled '1'
	option type 'tuic'
	option server 't.example.com'
	option server_port '443'
	option server_uuid 'uuid'
	option server_password 'pw'
	option security 'tls'
	option tuic_udp_over_stream '1'
	option tuic_udp_relay_mode 'native'
"
run_gen
check   "tuic udp_over_stream true" '"udp_over_stream": true'
nocheck "tuic no udp_relay_mode"    '"udp_relay_mode":'

echo "-- tuic outbound: defaults — empty optionals omit fields"
write_cfg "
config outbound 'tuic_min'
	option enabled '1'
	option type 'tuic'
	option server 't.example.com'
	option server_port '443'
	option server_uuid 'uuid'
	option server_password 'pw'
	option security 'tls'
"
run_gen
check   "tuic minimal type"        '"type": "tuic"'
nocheck "tuic no congestion"       '"congestion_control":'
nocheck "tuic no udp_relay_mode"   '"udp_relay_mode":'
nocheck "tuic no udp_over_stream"  '"udp_over_stream":'
nocheck "tuic no zero_rtt"         '"zero_rtt_handshake":'
nocheck "tuic no heartbeat"        '"heartbeat":'
nocheck "tuic no network"          '"network":'

echo "-- anytls outbound with all idle fields"
write_cfg "
config outbound 'at'
	option enabled '1'
	option type 'anytls'
	option server 'at.example.com'
	option server_port '443'
	option server_password 'at-pw'
	option security 'tls'
	option tls_server_name 'at.example.com'
	option anytls_idle_check_interval '15s'
	option anytls_idle_timeout '45s'
	option anytls_min_idle_session '5'
"
run_gen
check "anytls type"     '"type": "anytls"'
check "anytls server"   '"server": "at.example.com"'
check "anytls password" '"password": "at-pw"'
check "anytls idle_chk" '"idle_session_check_interval": "15s"'
check "anytls idle_to"  '"idle_session_timeout": "45s"'
check "anytls min_idle" '"min_idle_session": 5'
check "anytls tls"      '"enabled": true'

echo "-- anytls minimal — min_idle_session=0 dropped, idle fields omitted"
write_cfg "
config outbound 'at_min'
	option enabled '1'
	option type 'anytls'
	option server 'at.example.com'
	option server_port '443'
	option server_password 'at-pw'
	option security 'tls'
	option anytls_min_idle_session '0'
"
run_gen
check   "anytls minimal type"           '"type": "anytls"'
nocheck "no idle_check_interval unset" '"idle_session_check_interval":'
nocheck "no idle_timeout unset"        '"idle_session_timeout":'
nocheck "no min_idle when 0"           '"min_idle_session":'

echo "-- anytls drops transport/multiplex by design"
write_cfg "
config outbound 'at_no_transport'
	option enabled '1'
	option type 'anytls'
	option server 'at.example.com'
	option server_port '443'
	option server_password 'at-pw'
	option security 'tls'
	option transport 'ws'
	option transport_path '/should-be-ignored'
	option multiplex_enabled '1'
	option multiplex_protocol 'smux'
"
run_gen
check   "anytls type only"          '"type": "anytls"'
nocheck "no transport block"      '"transport":'
nocheck "no multiplex block"      '"multiplex":'
nocheck "no ignored ws path"      '/should-be-ignored'

# D1.1: trojan descriptor migration parity guard — byte-equal golden assertion.
# Must pass both before (legacy) and after (descriptor) the migration.
echo "-- trojan descriptor parity (D1.1 golden)"
golden='{ "type": "trojan", "tag": "t1", "server": "example.com", "server_port": 443, "password": "pw", "tls": { "enabled": true, "server_name": "example.com" } }'
actual=$(
	# shellcheck disable=SC2086
	"$UCODE_BIN" $UCODE_LIB_FLAGS -e '
let ob = require("outbound");
let s = { ".name":"t1", "server":"example.com", "server_port":"443",
          "server_password":"pw", "security":"tls", "tls_server_name":"example.com" };
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

echo "OK"
