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
	UCODE_LIB_FLAGS=""
elif [ -x "${UCODE_BIN:-}" ] && [ -d "${UCODE_STUB_DIR:-}" ]; then
	UCODE_LIB_FLAGS="-L $UCODE_STUB_DIR"
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

# generate.uc writes to /tmp/singbox-ui.json; copy it to out.json for checking.
run_gen() {
	# shellcheck disable=SC2086
	UCI_CONFIG_DIR="$TMPDIR" "$UCODE_BIN" $UCODE_LIB_FLAGS "$GENERATE_UC" >/dev/null \
		&& cp /tmp/singbox-ui.json "$TMPDIR/out.json"
}

# ---- fakeip + tproxy ----
echo "-- fakeip and tproxy inbound"
write_cfg "
config fakeip 'fakeip'
	option enabled '1'
	list inet4_range '198.18.0.0/15'
	list inet6_range 'fc00::/18'

config tproxy 'tproxy'
	option enabled '1'
	option port '7893'
"
run_gen
check "fakeip enabled"   '"enabled": true'         "$TMPDIR/out.json"
check "inet4_range"      '"198.18.0.0/15"'          "$TMPDIR/out.json"
check "tproxy inbound"   '"type": "tproxy"'         "$TMPDIR/out.json"
check "listen_port 7893" '"listen_port": 7893'      "$TMPDIR/out.json"

# ---- direct outbound ----
echo "-- direct outbound"
write_cfg "
config outbound 'direct_out'
	option action 'direct'
"
run_gen
check "direct tag"  '"tag": "direct_out"' "$TMPDIR/out.json"
check "direct type" '"type": "direct"'    "$TMPDIR/out.json"

# ---- block outbound ----
echo "-- block outbound"
write_cfg "
config outbound 'block_out'
	option action 'block'
"
run_gen
check "block tag"  '"tag": "block_out"' "$TMPDIR/out.json"
check "block type" '"type": "block"'    "$TMPDIR/out.json"

# ---- proxy via interface ----
echo "-- proxy via interface"
write_cfg "
config outbound 'via_wg0'
	option action 'proxy'
	option proxy_type 'interface'
	option interface 'wg0'
"
run_gen
check "interface proxy tag"  '"tag": "via_wg0"'        "$TMPDIR/out.json"
check "bind_interface"       '"bind_interface": "wg0"'  "$TMPDIR/out.json"

# ---- vless URL ----
echo "-- vless:// URL"
write_cfg "
config outbound 'my_vless'
	option action 'proxy'
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
	option action 'proxy'
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
	option action 'proxy'
	option proxy_type 'json'
	option proxy_json '{\"type\":\"vmess\",\"server\":\"json.example.com\",\"server_port\":8443,\"uuid\":\"abc-123\"}'
"
run_gen
check "json tag"    '"tag": "my_json_out"'        "$TMPDIR/out.json"
check "json type"   '"type": "vmess"'             "$TMPDIR/out.json"
check "json server" '"server": "json.example.com"' "$TMPDIR/out.json"
check "json port"   '"server_port": 8443'         "$TMPDIR/out.json"
check "json uuid"   '"uuid": "abc-123"'           "$TMPDIR/out.json"

echo "OK"
