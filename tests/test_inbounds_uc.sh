#!/bin/sh
# tests/test_inbounds_uc.sh
# Drives generate.uc with `inbound` sections and asserts the emitted
# sing-box inbounds[] array. Mirrors test_generate.sh's harness.
set -e

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
SANDBOX_DIR="$TMPDIR/sandbox"; mkdir -p "$SANDBOX_DIR/subs"
SANDBOX_CONFIG="$SANDBOX_DIR/singbox-ui.json"

check() {
	desc="$1"; pattern="$2"
	grep -q "$pattern" "$TMPDIR/out.json" \
		|| { echo "FAIL: $desc — '$pattern' not found"; cat "$TMPDIR/out.json"; exit 1; }
	echo "  PASS: $desc"
}
nocheck() {
	desc="$1"; pattern="$2"
	grep -q "$pattern" "$TMPDIR/out.json" \
		&& { echo "FAIL: $desc — '$pattern' should be absent"; cat "$TMPDIR/out.json"; exit 1; }
	echo "  PASS: $desc"
}
write_cfg() { printf '%s\n' "$1" > "$TMPDIR/singbox-ui"; }
run_gen() {
	# shellcheck disable=SC2086
	UCI_CONFIG_DIR="$TMPDIR" SINGBOX_TMPDIR="$SANDBOX_DIR/subs" SINGBOX_CONFIG="$SANDBOX_CONFIG" \
	"$UCODE_BIN" $UCODE_LIB_FLAGS "$GENERATE_UC" >"$TMPDIR/gen.stderr" 2>&1 \
		&& cp "$SANDBOX_CONFIG" "$TMPDIR/out.json"
}

echo "-- tproxy inbound from inbound section"
write_cfg "
config inbound 'tin'
	option enabled '1'
	option mode 'constructor'
	option protocol 'tproxy'
	option listen '::'
	option listen_port '7893'
	list interface 'br-lan'
	option nft_rules '1'
	option tcp_fast_open '1'
"
run_gen
check "tproxy type"       '"type": "tproxy"'
check "tproxy tag"        '"tag": "tin"'
check "tproxy listen"     '"listen": "::"'
check "tproxy port"       '"listen_port": 7893'
check "tproxy tfo"        '"tcp_fast_open": true'

echo "-- disabled inbound is skipped"
write_cfg "
config inbound 'off'
	option enabled '0'
	option protocol 'tproxy'
	option listen_port '7893'
"
run_gen
nocheck "disabled skipped" '"tag": "off"'

echo "-- listen-based inbound without port is skipped"
write_cfg "
config inbound 'noport'
	option enabled '1'
	option protocol 'shadowsocks'
	option server_password 'x'
"
run_gen
nocheck "noport skipped" '"tag": "noport"'

echo "-- tun inbound"
write_cfg "
config inbound 'tun0'
	option enabled '1'
	option mode 'constructor'
	option protocol 'tun'
	option interface_name 'singbox-tun'
	option inet4_address '172.19.0.1/30'
	option mtu '9000'
	option stack 'mixed'
	option auto_route '1'
"
run_gen
check "tun type"        '"type": "tun"'
check "tun ifname"      '"interface_name": "singbox-tun"'
check "tun address"     '"172.19.0.1/30"'
check "tun stack"       '"stack": "mixed"'
check "tun auto_route"  '"auto_route": true'
nocheck "tun has no listen_port" '"listen_port":'

echo "-- shadowsocks inbound"
write_cfg "
config inbound 'ss'
	option enabled '1'
	option protocol 'shadowsocks'
	option listen_port '8388'
	option shadowsocks_method 'aes-256-gcm'
	option server_password 'p@ss'
"
run_gen
check "ss type"     '"type": "shadowsocks"'
check "ss method"   '"method": "aes-256-gcm"'
check "ss password" '"password": "p@ss"'

echo "-- vless inbound with reality + ws transport"
write_cfg "
config inbound 'vl'
	option enabled '1'
	option protocol 'vless'
	option listen_port '443'
	option server_uuid 'uuid-1111'
	option vless_flow 'xtls-rprx-vision'
	option security 'reality'
	option reality_private_key 'PRIVKEY'
	option reality_short_id 'ab12'
	option reality_handshake_server 'www.example.com'
	option reality_handshake_server_port '443'
	option transport 'ws'
	option transport_path '/ray'
	option transport_host 'cdn.example.com'
"
run_gen
check "vless type"        '"type": "vless"'
check "vless uuid"        '"uuid": "uuid-1111"'
check "vless flow"        '"flow": "xtls-rprx-vision"'
check "vless reality"     '"reality":'
check "vless privkey"     '"private_key": "PRIVKEY"'
check "vless short_id"    '"ab12"'
check "vless handshake"   '"server": "www.example.com"'
check "vless transport"   '"type": "ws"'
check "vless ws path"     '"path": "/ray"'

echo "-- vmess inbound with alterId + tls"
write_cfg "
config inbound 'vm'
	option enabled '1'
	option protocol 'vmess'
	option listen_port '8443'
	option server_uuid 'uuid-2222'
	option vmess_alter_id '0'
	option security 'tls'
	option tls_server_name 'vm.example.com'
	option tls_certificate_path '/etc/ssl/cert.pem'
	option tls_key_path '/etc/ssl/key.pem'
"
run_gen
check "vmess type"     '"type": "vmess"'
check "vmess uuid"     '"uuid": "uuid-2222"'
check "vmess alterId"  '"alterId": 0'
check "vmess tls cert" '"certificate_path": "/etc/ssl/cert.pem"'

echo "-- trojan inbound"
write_cfg "
config inbound 'tj'
	option enabled '1'
	option protocol 'trojan'
	option listen_port '443'
	option server_password 'trojan-pw'
	option security 'tls'
	option tls_certificate_path '/c.pem'
	option tls_key_path '/k.pem'
"
run_gen
check "trojan type"     '"type": "trojan"'
check "trojan password" '"password": "trojan-pw"'

echo "-- hysteria2 inbound forces tls + obfs"
write_cfg "
config inbound 'hy'
	option enabled '1'
	option protocol 'hysteria2'
	option listen_port '8443'
	option server_password 'hy-pw'
	option hysteria2_obfs_type 'salamander'
	option hysteria2_obfs_password 'obfs-pw'
	option up_mbps '100'
	option down_mbps '200'
	option tls_certificate_path '/c.pem'
	option tls_key_path '/k.pem'
"
run_gen
check "hy2 type"      '"type": "hysteria2"'
check "hy2 password"  '"password": "hy-pw"'
check "hy2 obfs type" '"type": "salamander"'
check "hy2 obfs pw"   '"password": "obfs-pw"'
check "hy2 up"        '"up_mbps": 100'
check "hy2 tls"       '"enabled": true'

echo "-- mode=json passes raw object through with injected tag"
write_cfg "
config inbound 'raw'
	option enabled '1'
	option mode 'json'
	option inbound_json '{\"type\":\"mixed\",\"listen\":\"127.0.0.1\",\"listen_port\":2080}'
"
run_gen
check "json type"   '"type": "mixed"'
check "json tag"    '"tag": "raw"'
check "json listen" '"listen": "127.0.0.1"'

echo "-- mode=json invalid JSON → inbound skipped + warning"
write_cfg "
config inbound 'bad'
	option enabled '1'
	option mode 'json'
	option inbound_json '{ not json'
"
run_gen || true
nocheck "bad json skipped" '"tag": "bad"'
grep -qi 'invalid inbound_json' "$TMPDIR/gen.stderr" \
	|| { echo "FAIL: missing warning for invalid inbound_json"; cat "$TMPDIR/gen.stderr"; exit 1; }
echo "  PASS: invalid inbound_json warned + skipped"

echo "-- extra_json merges over constructed object"
write_cfg "
config inbound 'tp'
	option enabled '1'
	option protocol 'tproxy'
	option listen_port '7893'
	option extra_json '{\"sniff\":true,\"sniff_override_destination\":true}'
"
run_gen
check "extra sniff"          '"sniff": true'
check "extra sniff_override" '"sniff_override_destination": true'

echo "OK"
