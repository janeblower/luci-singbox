#!/bin/sh
# tests/test_inbounds_uc.sh
# Drives generate.uc with `inbound` sections and asserts the emitted
# sing-box inbounds[] array. Mirrors test_generate.sh's harness.
set -e

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
	option tls_enabled '1'
	option reality_enabled '1'
	option reality_private_key 'PRIVKEY'
	option reality_short_id 'ab12'
	option reality_handshake_server 'www.example.com'
	option reality_handshake_server_port '443'
	option transport_type 'ws'
	option transport_path '/ray'
	option transport_host 'cdn.example.com'
"
run_gen
check "vless type"        '"type": "vless"'
check "vless uuid"        '"uuid": "uuid-1111"'
check "vless flow"        '"flow": "xtls-rprx-vision"'
check "vless reality"     '"reality":'
check "vless privkey"     '"private_key": "PRIVKEY"'
# sing-box 1.12: tls.reality.short_id is a single string, not an array.
check "vless short_id"    '"short_id": "ab12"'
nocheck "no short_id array" '"short_id": \['
check "vless handshake"   '"server": "www.example.com"'
check "vless transport"   '"type": "ws"'
check "vless ws path"     '"path": "/ray"'

echo "-- trojan inbound"
write_cfg "
config inbound 'tj'
	option enabled '1'
	option protocol 'trojan'
	option listen_port '443'
	option server_password 'trojan-pw'
	option tls_enabled '1'
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
	option obfs_type 'salamander'
	option obfs_password 'obfs-pw'
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

echo "-- extra_json is no longer honoured for inbounds (field deprecated)"
write_cfg "
config inbound 'tp'
	option enabled '1'
	option protocol 'tproxy'
	option listen_port '7893'
	option extra_json '{\"sniff\":true,\"sniff_override_destination\":true}'
"
run_gen
nocheck "extra not merged inbound" '"sniff": true'

echo "-- vless inbound with http transport (multi-host list + tls alpn list)"
write_cfg "
config inbound 'http_in'
	option enabled '1'
	option protocol 'vless'
	option listen_port '8445'
	option server_uuid 'uuid-9999'
	option transport_type 'http'
	option transport_path '/api'
	list   transport_hosts 'a.example.com'
	list   transport_hosts 'b.example.com'
	option tls_enabled '1'
	option tls_certificate_path '/c.pem'
	option tls_key_path '/k.pem'
	list   tls_alpn 'h2'
	list   tls_alpn 'http/1.1'
"
run_gen
check "http transport"     '"type": "http"'
check "host a kept"        '"a.example.com"'
check "host b kept"        '"b.example.com"'
check "alpn h2 kept"       '"h2"'
check "alpn http1 kept"    '"http/1.1"'

echo "-- direct (DNS) inbound on 127.0.0.53:53"
write_cfg "
config inbound 'dns_in'
	option enabled '1'
	option protocol 'direct'
	option listen '127.0.0.53'
	option listen_port '53'
	option network 'udp'
"
run_gen
check "direct type"      '"type": "direct"'
check "direct tag"       '"tag": "dns_in"'
check "direct listen"    '"listen": "127.0.0.53"'
check "direct port"      '"listen_port": 53'
check "direct network"   '"network": "udp"'

echo "-- mode='json' is no longer recognised; section skipped"
write_cfg "
config inbound 'raw'
	option enabled '1'
	option mode 'json'
	option inbound_json '{\"type\":\"mixed\",\"listen\":\"127.0.0.1\",\"listen_port\":2080}'
"
run_gen
nocheck "raw mode skipped" '"tag": "raw"'

echo "-- mode='constructor' is treated as no-op (protocol-first works)"
write_cfg "
config inbound 'tin'
	option enabled '1'
	option mode 'constructor'
	option protocol 'tproxy'
	option listen_port '7893'
"
run_gen
check "constructor still works" '"tag": "tin"'

echo "-- vless inbound with multiplex + xhttp transport"
write_cfg "
config inbound 'vl2'
	option enabled '1'
	option protocol 'vless'
	option listen_port '443'
	option server_uuid 'uuid-3'
	option transport_type 'xhttp'
	option transport_path '/x'
	option transport_xhttp_mode 'stream-up'
	option multiplex_enabled '1'
	option multiplex_protocol 'smux'
	option multiplex_max_connections '4'
"
run_gen
check "vless mux"          '"multiplex":'
check "vless mux smux"     '"protocol": "smux"'
check "vless mux max"      '"max_connections": 4'
check "vless xhttp"        '"type": "xhttp"'
check "vless xhttp mode"   '"mode": "stream-up"'

echo "-- hysteria2 inbound with masquerade + utls"
write_cfg "
config inbound 'hy'
	option enabled '1'
	option protocol 'hysteria2'
	option listen_port '8443'
	option server_password 'p'
	option up_mbps '100'
	option down_mbps '50'
	option masquerade 'https://www.example.com'
	option tls_server_name 'hy.example.com'
	option tls_certificate_path '/etc/ssl/cert.pem'
	option tls_key_path '/etc/ssl/key.pem'
"
run_gen
check "hy2 masquerade" '"masquerade": "https://www.example.com"'

echo "-- hysteria2 inbound with brutal_debug + ignore_client_bandwidth + limits"
write_cfg "
config inbound 'hy2lim'
	option enabled '1'
	option protocol 'hysteria2'
	option listen_port '8443'
	option server_password 'pw'
	option up_mbps '500'
	option down_mbps '500'
	option brutal_debug '1'
	option ignore_client_bandwidth '1'
"
run_gen
check "hy2 up_mbps"                '"up_mbps": 500'
check "hy2 down_mbps"              '"down_mbps": 500'
check "hy2 brutal_debug"           '"brutal_debug": true'
check "hy2 ignore_client_bandwidth" '"ignore_client_bandwidth": true'

echo "-- hysteria2 inbound without debug/ignore flags omits both"
write_cfg "
config inbound 'hy2def'
	option enabled '1'
	option protocol 'hysteria2'
	option listen_port '8443'
	option server_password 'pw'
"
run_gen
nocheck "no brutal_debug when unset" '"brutal_debug":'
nocheck "no ignore_client_bandwidth when unset" '"ignore_client_bandwidth":'

echo "-- vless inbound with ECH (server-side: key + key_path)"
write_cfg "
config inbound 'vech'
	option enabled '1'
	option protocol 'vless'
	option listen_port '4443'
	option server_uuid 'uuid-ech'
	option tls_enabled '1'
	option tls_server_name 'ech.example.com'
	option tls_certificate_path '/etc/ssl/cert.pem'
	option tls_key_path '/etc/ssl/key.pem'
	option tls_ech_enabled '1'
	list   tls_ech_key '-----BEGIN ECH KEY-----'
	list   tls_ech_key 'AAAA'
	list   tls_ech_key '-----END ECH KEY-----'
	option tls_ech_key_path '/etc/ssl/ech.key'
"
run_gen
check  "ech enabled"      '"ech":'
check  "ech.enabled true" '"enabled": true'
check  "ech.key array"    '"key": \['
check  "ech.key line 1"   '"-----BEGIN ECH KEY-----"'
check  "ech.key_path"     '"key_path": "/etc/ssl/ech.key"'
# Deprecated in 1.12 / removed in 1.13 — never emitted.
nocheck "no pq_signature_schemes_enabled" 'pq_signature_schemes_enabled'

echo "-- vless inbound without tls_ech omits the ech block"
write_cfg "
config inbound 'noech'
	option enabled '1'
	option protocol 'vless'
	option listen_port '4444'
	option server_uuid 'uuid-noech'
	option tls_enabled '1'
	option tls_server_name 'plain.example.com'
"
run_gen
nocheck "no ech when not requested" '"ech":'

echo "-- shadowsocks inbound multi-user + network + multiplex"
write_cfg "
config inbound 'ss_multi'
	option enabled '1'
	option protocol 'shadowsocks'
	option listen_port '8388'
	option shadowsocks_method '2022-blake3-aes-128-gcm'
	option server_password 'should-be-ignored'
	list   ss_user 'alice:2022-blake3-aes-128-gcm:pw1'
	list   ss_user 'bob:2022-blake3-aes-128-gcm:pw2'
	option network 'tcp'
	option multiplex_enabled '1'
	option multiplex_protocol 'smux'
"
run_gen
check "ss multi type"     '"type": "shadowsocks"'
check "ss multi method"   '"method": "2022-blake3-aes-128-gcm"'
check "ss user alice"     '"name": "alice"'
check "ss user alice pw"  '"password": "pw1"'
check "ss user bob"       '"name": "bob"'
check "ss user bob pw"    '"password": "pw2"'
check "ss network=tcp"    '"network": "tcp"'
check "ss multiplex"      '"protocol": "smux"'
# Top-level password dropped when users[] present.
nocheck "no top-level password" '"password": "should-be-ignored"'

echo "-- shadowsocks inbound single-user (no ss_user list)"
write_cfg "
config inbound 'ss_single'
	option enabled '1'
	option protocol 'shadowsocks'
	option listen_port '8388'
	option shadowsocks_method 'aes-128-gcm'
	option server_password 'single-pw'
"
run_gen
check "ss single type"     '"type": "shadowsocks"'
check "ss single password" '"password": "single-pw"'
nocheck "no users array"   '"users":'
nocheck "no network field" '"network":'
nocheck "no multiplex"     '"multiplex":'

echo "-- shadowsocks inbound malformed ss_user entries are skipped"
write_cfg "
config inbound 'ss_bad'
	option enabled '1'
	option protocol 'shadowsocks'
	option listen_port '8388'
	option shadowsocks_method 'aes-128-gcm'
	list   ss_user 'no-colon-here'
	list   ss_user 'only:two-parts'
	list   ss_user 'good:aes-128-gcm:gp'
"
run_gen
check "ss good user"        '"name": "good"'
check "ss good password"    '"password": "gp"'
nocheck "no malformed name"  '"name": "no-colon-here"'
nocheck "no two-parts name"  '"name": "only"'

echo "-- vless inbound multi-user with per-user flow"
write_cfg "
config inbound 'vl_multi'
	option enabled '1'
	option protocol 'vless'
	option listen_port '4443'
	option server_uuid 'section-uuid'
	option vless_flow 'xtls-rprx-vision'
	list   inbound_user 'alice:uuid-aaa:xtls-rprx-vision'
	list   inbound_user 'bob:uuid-bbb:none'
	list   inbound_user 'carol:uuid-ccc'
"
run_gen
check "vl-multi alice flow"    '"flow": "xtls-rprx-vision"'
check "vl-multi alice uuid"    '"uuid": "uuid-aaa"'
check "vl-multi bob uuid"      '"uuid": "uuid-bbb"'
check "vl-multi carol uuid"    '"uuid": "uuid-ccc"'
nocheck "no section single-user uuid leak" '"uuid": "section-uuid"'

# D1.5.3: shadowsocks inbound descriptor parity (golden).
# Must pass both before (legacy) and after (descriptor) the migration.
echo "-- shadowsocks inbound descriptor parity: multi-user (D1.5.3 golden)"
# S2.2: sing-box shadowsocks inbound users carry NO per-user method (the cipher
# is the shared inbound-root "method"); golden updated to drop the invalid key.
golden='{ "type": "shadowsocks", "tag": "ss_in1", "listen": "::", "listen_port": 8388, "method": "2022-blake3-aes-128-gcm", "network": "tcp", "users": [ { "name": "alice", "password": "pwA" }, { "name": "bob", "password": "pwB" } ] }'
actual=$(
	# shellcheck disable=SC2086
	"$UCODE_BIN" $UCODE_LIB_FLAGS -e '
let inb = require("inbound");
let s = { ".name":"ss_in1", "protocol":"shadowsocks", "listen":"::", "listen_port":"8388",
          "shadowsocks_method":"2022-blake3-aes-128-gcm",
          "ss_user":["alice:2022-blake3-aes-128-gcm:pwA","bob:2022-blake3-aes-128-gcm:pwB"], "network":"tcp" };
printf("%J", inb.build_one(s));
'
)
if [ "$actual" = "$golden" ]; then
	echo "  PASS: shadowsocks inbound parity (multi-user)"
else
	echo "FAIL: shadowsocks inbound parity (multi-user)"
	echo "  expected: $golden"
	echo "  actual:   $actual"
	exit 1
fi

echo "-- shadowsocks inbound descriptor parity: single-user fallback (D1.5.3 golden)"
golden='{ "type": "shadowsocks", "tag": "ss_in2", "listen": "::", "listen_port": 8388, "method": "aes-128-gcm", "password": "pw" }'
actual=$(
	# shellcheck disable=SC2086
	"$UCODE_BIN" $UCODE_LIB_FLAGS -e '
let inb = require("inbound");
let s = { ".name":"ss_in2", "protocol":"shadowsocks", "listen_port":"8388",
          "shadowsocks_method":"aes-128-gcm", "server_password":"pw" };
printf("%J", inb.build_one(s));
'
)
if [ "$actual" = "$golden" ]; then
	echo "  PASS: shadowsocks inbound parity (single-user fallback)"
else
	echo "FAIL: shadowsocks inbound parity (single-user fallback)"
	echo "  expected: $golden"
	echo "  actual:   $actual"
	exit 1
fi

# D1.5.2: trojan inbound descriptor parity (golden).
# Must pass both before (legacy) and after (descriptor) the migration.
echo "-- trojan inbound descriptor parity (D1.5.2 golden)"
golden='{ "type": "trojan", "tag": "in_t1", "listen": "::", "listen_port": 443, "users": [ { "name": "in_t1", "password": "pw" } ], "tls": { "enabled": true, "certificate_path": "/etc/ssl/c.pem", "key_path": "/etc/ssl/k.pem" } }'
actual=$(
	# shellcheck disable=SC2086
	"$UCODE_BIN" $UCODE_LIB_FLAGS -e '
let inb = require("inbound");
let s = { ".name":"in_t1", "protocol":"trojan", "listen":"::", "listen_port":"443",
          "server_password":"pw", "tls_enabled":"1",
          "tls_certificate_path":"/etc/ssl/c.pem", "tls_key_path":"/etc/ssl/k.pem" };
printf("%J", inb.build_one(s));
'
)
if [ "$actual" = "$golden" ]; then
	echo "  PASS: trojan inbound parity"
else
	echo "FAIL: trojan inbound parity"
	echo "  expected: $golden"
	echo "  actual:   $actual"
	exit 1
fi

# D1.5.4: vless inbound descriptor parity (golden).
# Must pass both before (legacy) and after (descriptor) the migration.
echo "-- vless inbound descriptor parity: multi-user (D1.5.4 golden)"
golden='{ "type": "vless", "tag": "v_in1", "listen": "::", "listen_port": 443, "users": [ { "name": "alice", "uuid": "11111111-1111-1111-1111-111111111111" }, { "name": "bob", "uuid": "22222222-2222-2222-2222-222222222222", "flow": "xtls-rprx-vision" } ], "tls": { "enabled": true, "certificate_path": "/etc/ssl/cert.pem", "key_path": "/etc/ssl/key.pem" } }'
actual=$(
	# shellcheck disable=SC2086
	"$UCODE_BIN" $UCODE_LIB_FLAGS -e '
let inb = require("inbound");
let s = { ".name":"v_in1", "protocol":"vless", "listen":"::", "listen_port":"443",
          "inbound_user":["alice:11111111-1111-1111-1111-111111111111",
                          "bob:22222222-2222-2222-2222-222222222222:xtls-rprx-vision"],
          "tls_enabled":"1",
          "tls_certificate_path":"/etc/ssl/cert.pem", "tls_key_path":"/etc/ssl/key.pem" };
printf("%J", inb.build_one(s));
'
)
if [ "$actual" = "$golden" ]; then
	echo "  PASS: vless inbound parity (multi-user)"
else
	echo "FAIL: vless inbound parity (multi-user)"
	echo "  expected: $golden"
	echo "  actual:   $actual"
	exit 1
fi

echo "-- vless inbound descriptor parity: single-user (D1.5.4 golden)"
golden='{ "type": "vless", "tag": "v_in2", "listen": "::", "listen_port": 443, "users": [ { "name": "v_in2", "uuid": "33333333-3333-3333-3333-333333333333", "flow": "xtls-rprx-vision" } ], "tls": { "enabled": true, "certificate_path": "/etc/ssl/cert.pem", "key_path": "/etc/ssl/key.pem" } }'
actual=$(
	# shellcheck disable=SC2086
	"$UCODE_BIN" $UCODE_LIB_FLAGS -e '
let inb = require("inbound");
let s = { ".name":"v_in2", "protocol":"vless", "listen":"::", "listen_port":"443",
          "server_uuid":"33333333-3333-3333-3333-333333333333",
          "vless_flow":"xtls-rprx-vision",
          "tls_enabled":"1",
          "tls_certificate_path":"/etc/ssl/cert.pem", "tls_key_path":"/etc/ssl/key.pem" };
printf("%J", inb.build_one(s));
'
)
if [ "$actual" = "$golden" ]; then
	echo "  PASS: vless inbound parity (single-user)"
else
	echo "FAIL: vless inbound parity (single-user)"
	echo "  expected: $golden"
	echo "  actual:   $actual"
	exit 1
fi

# D1.5.6: hysteria2 inbound descriptor parity (golden).
# Must pass both before (legacy) and after (descriptor) the migration.
echo "-- hysteria2 inbound descriptor parity: full (D1.5.6 golden)"
golden='{ "type": "hysteria2", "tag": "h2_in1", "listen": "::", "listen_port": 443, "users": [ { "name": "h2_in1", "password": "pw" } ], "obfs": { "type": "salamander", "password": "obfspw" }, "up_mbps": 100, "down_mbps": 200, "masquerade": "https://example.com", "brutal_debug": true, "ignore_client_bandwidth": true, "tls": { "enabled": true, "server_name": "h2.example.com", "certificate_path": "/etc/ssl/c.pem", "key_path": "/etc/ssl/k.pem" } }'
actual=$(
	# shellcheck disable=SC2086
	"$UCODE_BIN" $UCODE_LIB_FLAGS -e '
let inb = require("inbound");
let s = { ".name":"h2_in1", "protocol":"hysteria2", "listen_port":"443",
          "server_password":"pw",
          "obfs_type":"salamander", "obfs_password":"obfspw",
          "up_mbps":"100", "down_mbps":"200",
          "masquerade":"https://example.com",
          "brutal_debug":"1", "ignore_client_bandwidth":"1",
          "tls_server_name":"h2.example.com",
          "tls_certificate_path":"/etc/ssl/c.pem", "tls_key_path":"/etc/ssl/k.pem" };
printf("%J", inb.build_one(s));
'
)
if [ "$actual" = "$golden" ]; then
	echo "  PASS: hysteria2 inbound parity (full)"
else
	echo "FAIL: hysteria2 inbound parity (full)"
	echo "  expected: $golden"
	echo "  actual:   $actual"
	exit 1
fi

echo "-- hysteria2 inbound descriptor parity: minimal (D1.5.6 golden)"
golden='{ "type": "hysteria2", "tag": "h2_in2", "listen": "::", "listen_port": 443, "users": [ { "name": "h2_in2", "password": "pw" } ], "tls": { "enabled": true, "server_name": "h2.example.com", "certificate_path": "/etc/ssl/c.pem", "key_path": "/etc/ssl/k.pem" } }'
actual=$(
	# shellcheck disable=SC2086
	"$UCODE_BIN" $UCODE_LIB_FLAGS -e '
let inb = require("inbound");
let s = { ".name":"h2_in2", "protocol":"hysteria2", "listen_port":"443",
          "server_password":"pw",
          "tls_server_name":"h2.example.com",
          "tls_certificate_path":"/etc/ssl/c.pem", "tls_key_path":"/etc/ssl/k.pem" };
printf("%J", inb.build_one(s));
'
)
if [ "$actual" = "$golden" ]; then
	echo "  PASS: hysteria2 inbound parity (minimal)"
else
	echo "FAIL: hysteria2 inbound parity (minimal)"
	echo "  expected: $golden"
	echo "  actual:   $actual"
	exit 1
fi

echo "OK"
