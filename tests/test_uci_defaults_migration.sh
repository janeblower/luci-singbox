#!/bin/sh
# tests/test_uci_defaults_migration.sh
# Verifies that uci-defaults migrates legacy `list inet4_range` /
# `list inet6_range` to scalar `option` form.
#
# Note: the migration script uses bare `uci` (no `-c`), and this build of uci
# does not honour any UCI_*_DIR env var — only the `-c <path>` flag works. So
# we stage the test config directly into /etc/config/. That's safe because
# this test is expected to run inside a disposable container (the CI workflow
# runs it in openwrt/rootfs); it refuses to run if /etc/config/singbox-ui
# already exists, to avoid clobbering a real host install.
set -e

if ! command -v uci >/dev/null 2>&1; then
    echo "SKIP: uci binary not available"; exit 0
fi

CONFIG=/etc/config/singbox-ui
if [ -e "$CONFIG" ]; then
    echo "SKIP: $CONFIG already exists — refusing to clobber a real install"
    exit 0
fi

cleanup() {
    rm -f "$CONFIG"
}
trap cleanup EXIT

# Seed legacy config (list form) directly in /etc/config.
mkdir -p /etc/config
cat >"$CONFIG" <<'EOF'
config fakeip 'fakeip'
	option enabled '1'
	list inet4_range '198.18.0.0/15'
	list inet4_range '198.30.0.0/15'
	list inet6_range 'fc00::/18'
EOF

log=$(mktemp)
trap 'cleanup; rm -f "$log"' EXIT
IPKG_INSTROOT='' sh luci-app-singbox-ui/root/etc/uci-defaults/99-luci-app-singbox-ui \
    >"$log" 2>&1 || {
        echo "FAIL: uci-defaults script crashed:"
        cat "$log"; exit 1
    }

result=$(uci get singbox-ui.fakeip.inet4_range)
case "$result" in
    "198.18.0.0/15") echo "  PASS: inet4_range migrated to first element ($result)";;
    *)               echo "FAIL: expected '198.18.0.0/15', got '$result'"; exit 1;;
esac

result6=$(uci get singbox-ui.fakeip.inet6_range)
case "$result6" in
    "fc00::/18") echo "  PASS: inet6_range migrated to first element ($result6)";;
    *)           echo "FAIL: expected 'fc00::/18', got '$result6'"; exit 1;;
esac

# Verify it's now option, not list — `uci show` would emit multiple lines
# (one per element) for a list option.
lines=$(uci show singbox-ui.fakeip | grep -c '\.inet4_range=')
[ "$lines" = "1" ] || { echo "FAIL: expected one inet4_range entry, got $lines"; exit 1; }
echo "  PASS: inet4_range is scalar (one entry in show)"

echo "-- tproxy section → inbound migration + drop expose"
cat >"$CONFIG" <<'EOF'
config tproxy 'tproxy'
	option enabled '1'
	option port '7893'
	option hijack_dns '1'
	list interface 'br-lan'
	list interface 'br-guest'

config outbound 'p'
	option proxy_type 'interface'
	option interface 'eth0'
	option expose_proxy '1'
	option expose_type 'socks'
	option expose_port '1080'
EOF

IPKG_INSTROOT='' sh luci-app-singbox-ui/root/etc/uci-defaults/99-luci-app-singbox-ui \
	>"$log" 2>&1 || { echo "FAIL: migration crashed"; cat "$log"; exit 1; }

# tproxy section removed
uci -q get singbox-ui.tproxy >/dev/null 2>&1 \
	&& { echo "FAIL: tproxy section should be deleted"; exit 1; }
echo "  PASS: tproxy section removed"

# inbound 'tproxy_in' created with mapped values
[ "$(uci get singbox-ui.tproxy_in.protocol)" = "tproxy" ] \
	|| { echo "FAIL: tproxy_in.protocol != tproxy"; exit 1; }
[ "$(uci get singbox-ui.tproxy_in.listen_port)" = "7893" ] \
	|| { echo "FAIL: tproxy_in.listen_port != 7893"; exit 1; }
[ "$(uci get singbox-ui.tproxy_in.hijack_dns)" = "1" ] \
	|| { echo "FAIL: tproxy_in.hijack_dns != 1"; exit 1; }
[ "$(uci get singbox-ui.tproxy_in.nft_rules)" = "1" ] \
	|| { echo "FAIL: tproxy_in.nft_rules != 1"; exit 1; }
ifaces=$(uci -q show singbox-ui.tproxy_in.interface | grep -c '\.interface=')
[ "$ifaces" = "1" ] || { echo "FAIL: interface should be a single list option line"; uci show singbox-ui.tproxy_in; exit 1; }
uci get singbox-ui.tproxy_in.interface | grep -q 'br-lan' \
	|| { echo "FAIL: interface list missing br-lan"; exit 1; }
echo "  PASS: tproxy_in inbound created from tproxy section"

# expose_* options dropped from outbound
uci -q get singbox-ui.p.expose_proxy >/dev/null 2>&1 \
	&& { echo "FAIL: expose_proxy should be dropped"; exit 1; }
echo "  PASS: expose_* dropped from outbound"

# Idempotent: re-run must not crash or recreate the tproxy section
IPKG_INSTROOT='' sh luci-app-singbox-ui/root/etc/uci-defaults/99-luci-app-singbox-ui \
	>"$log" 2>&1 || { echo "FAIL: rerun crashed"; cat "$log"; exit 1; }
uci -q get singbox-ui.tproxy >/dev/null 2>&1 \
	&& { echo "FAIL: rerun resurrected tproxy section"; exit 1; }
echo "  PASS: migration idempotent"

echo "OK"
