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

echo "OK"
