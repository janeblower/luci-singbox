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

echo "OK"
