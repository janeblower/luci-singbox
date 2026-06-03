#!/bin/sh
# tests/test_defaults.sh — generate.uc over the SHIPPED default config.
# Proves the out-of-the-box bypass setup produces the intended sing-box JSON.
set -e
if command -v ucode >/dev/null 2>&1; then
	UCODE_BIN=ucode; UCODE_LIB_FLAGS="-L ${UCODE_APP_LIB_DIR:-$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/lib}"
elif [ -x "${UCODE_BIN:-}" ] && [ -d "${UCODE_STUB_DIR:-}" ]; then
	UCODE_LIB_FLAGS="-L $UCODE_STUB_DIR -L ${UCODE_APP_LIB_DIR:-$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/lib}"
	[ -n "${UCODE_LIB_DIR:-}" ] && UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L $UCODE_LIB_DIR"
else echo "SKIP: ucode not available"; exit 0; fi

GENERATE_UC=luci-app-singbox-ui/root/usr/share/singbox-ui/generate.uc
DEFAULT_CFG=luci-app-singbox-ui/root/etc/config/singbox-ui
TMPDIR=$(mktemp -d); trap 'rm -rf "$TMPDIR"' EXIT
SANDBOX_DIR="$TMPDIR/sandbox"; mkdir -p "$SANDBOX_DIR/subs"; SANDBOX_CONFIG="$SANDBOX_DIR/singbox-ui.json"
check() { grep -q "$2" "$TMPDIR/out.json" || { echo "FAIL: $1 — '$2'"; cat "$TMPDIR/out.json"; exit 1; }; echo "  PASS: $1"; }

cp "$DEFAULT_CFG" "$TMPDIR/singbox-ui"
# shellcheck disable=SC2086
UCI_CONFIG_DIR="$TMPDIR" SINGBOX_TMPDIR="$SANDBOX_DIR/subs" SINGBOX_CONFIG="$SANDBOX_CONFIG" \
	"$UCODE_BIN" $UCODE_LIB_FLAGS "$GENERATE_UC" >"$TMPDIR/gen.stderr" 2>&1 || {
		echo "FAIL: generate.uc errored on default config"; cat "$TMPDIR/gen.stderr"; exit 1; }
cp "$SANDBOX_CONFIG" "$TMPDIR/out.json"

echo "-- inbound: tproxy + hijack-dns"
check "tproxy inbound" '"type": "tproxy"'
check "tproxy port"    '"listen_port": 7893'
check "hijack-dns"     '"action": "hijack-dns"'

echo "-- rule-sets: russia_inside + discord"
check "russia_inside tag" '"tag": "russia_inside"'
check "discord tag"       '"tag": "discord"'

echo "-- outbound direct_wan + route rule"
check "direct_wan tag"    '"tag": "direct_wan"'
check "direct_wan bind"   '"bind_interface": "wan"'
check "route to wan"      '"outbound": "direct_wan"'

echo "-- dns: fakeip + google + rule + final"
check "fakeip server"  '"type": "fakeip"'
check "google server"  '"server": "8.8.8.8"'
grep -q '"detour":' "$TMPDIR/out.json" && { echo "FAIL: default DNS must not detour to implicit direct"; exit 1; }
echo "  PASS: no DNS detour to implicit outbound"
check "dns rule"       '"action": "route"'
check "dns final"      '"final": "google"'
check "dns strategy"   '"strategy": "prefer_ipv4"'

echo "-- cache: enabled with fakeip storage"
check "cache enabled"       '"cache_file":'
check "cache path /tmp"     '"path": "/tmp/singbox-ui-cache.db"'
check "cache store_fakeip"  '"store_fakeip": true'

# Final, strongest gate: hand the generated config to the actual daemon's
# config validator. Catches any new "fatal at startup" footgun the assertions
# above would miss (this is exactly how the default-DNS-detour crash slipped
# through). Skipped if sing-box isn't installed (e.g. plain host runs).
if command -v sing-box >/dev/null 2>&1; then
	sing-box check -c "$TMPDIR/out.json" >"$TMPDIR/sb.err" 2>&1 || {
		echo "FAIL: sing-box check rejected default config"; cat "$TMPDIR/sb.err"; exit 1; }
	echo "  PASS: sing-box check accepts default config"
fi

echo "OK"
