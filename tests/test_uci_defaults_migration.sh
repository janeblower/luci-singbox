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
. "$(dirname "$0")/lib/sb_helpers.sh"

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
IPKG_INSTROOT='' sh ${SB_BACKEND_ROOT}/etc/uci-defaults/99-luci-singbox-ui \
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

IPKG_INSTROOT='' sh ${SB_BACKEND_ROOT}/etc/uci-defaults/99-luci-singbox-ui \
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
IPKG_INSTROOT='' sh ${SB_BACKEND_ROOT}/etc/uci-defaults/99-luci-singbox-ui \
	>"$log" 2>&1 || { echo "FAIL: rerun crashed"; cat "$log"; exit 1; }
uci -q get singbox-ui.tproxy >/dev/null 2>&1 \
	&& { echo "FAIL: rerun resurrected tproxy section"; exit 1; }
echo "  PASS: migration idempotent"

echo "-- DNS model migration (fakeip / dns_outbound / ruleset.dns_fakeip)"
rm -f "$CONFIG"
cat >"$CONFIG" <<'EOF'
config fakeip 'fakeip'
	option enabled '1'
	option inet4_range '198.18.0.0/15'
	option inet6_range 'fc00::/18'

config dns_outbound 'dns_outbound'
	option enabled '1'
	option address 'https://dns.google/dns-query'
	option detour 'direct'

config ruleset 'ru'
	option enabled '1'
	option type 'remote'
	option url 'https://example.com/ru.srs'
	option dns_fakeip '1'
	option dns_fakeip_tag 'fakeip'
EOF

IPKG_INSTROOT='' sh ${SB_BACKEND_ROOT}/etc/uci-defaults/99-luci-singbox-ui \
	>"$log" 2>&1 || { echo "FAIL: DNS migration crashed"; cat "$log"; exit 1; }

[ "$(uci get singbox-ui.fakeip 2>/dev/null)" = "dns_server" ] \
	|| { echo "FAIL: fakeip section type != dns_server"; uci show singbox-ui | grep fakeip; exit 1; }
[ "$(uci get singbox-ui.fakeip.type 2>/dev/null)" = "fakeip" ] \
	|| { echo "FAIL: fakeip.type != fakeip"; exit 1; }
echo "  PASS: fakeip → dns_server"

[ "$(uci get singbox-ui.out_dns.type 2>/dev/null)" = "https" ] \
	|| { echo "FAIL: dns_outbound not converted (type)"; exit 1; }
[ "$(uci get singbox-ui.out_dns.server 2>/dev/null)" = "dns.google" ] \
	|| { echo "FAIL: out_dns.server wrong"; exit 1; }
[ "$(uci get singbox-ui.out_dns.path 2>/dev/null)" = "/dns-query" ] \
	|| { echo "FAIL: out_dns.path != /dns-query"; exit 1; }
[ "$(uci get singbox-ui.dns.final 2>/dev/null)" = "out_dns" ] \
	|| { echo "FAIL: dns.final != out_dns"; exit 1; }
uci -q get singbox-ui.dns_outbound >/dev/null 2>&1 && { echo "FAIL: dns_outbound not deleted"; exit 1; }
echo "  PASS: dns_outbound → dns_server + final"

uci -q get singbox-ui.ru.dns_fakeip >/dev/null 2>&1 && { echo "FAIL: ruleset.dns_fakeip not removed"; exit 1; }
rule=$(uci -q show singbox-ui | sed -n 's/^singbox-ui\.\([^.]*\)=dns_rule$/\1/p' | head -n1)
[ -n "$rule" ] || { echo "FAIL: no dns_rule created"; exit 1; }
[ "$(uci get "singbox-ui.$rule.server")" = "fakeip" ] || { echo "FAIL: dns_rule.server != fakeip"; exit 1; }
echo "  PASS: ruleset.dns_fakeip → dns_rule"

IPKG_INSTROOT='' sh ${SB_BACKEND_ROOT}/etc/uci-defaults/99-luci-singbox-ui \
	>"$log" 2>&1 || { echo "FAIL: DNS migration rerun crashed"; cat "$log"; exit 1; }
uci -q get singbox-ui.dns_outbound >/dev/null 2>&1 && { echo "FAIL: rerun resurrected dns_outbound"; exit 1; }
echo "  PASS: DNS migration idempotent"

echo "-- clash_api secret generated + idempotent"
rm -f "$CONFIG"
cat >"$CONFIG" <<'EOF'
config clash_api 'clash_api'
	option enabled '0'
	option listen '127.0.0.1'
	option port '9090'
EOF
IPKG_INSTROOT='' sh ${SB_BACKEND_ROOT}/etc/uci-defaults/99-luci-singbox-ui \
	>"$log" 2>&1 || { echo "FAIL: secret gen crashed"; cat "$log"; exit 1; }
sec1=$(uci -q get singbox-ui.clash_api.secret 2>/dev/null || true)
[ -n "$sec1" ] || { echo "FAIL: secret not generated"; exit 1; }
echo "  PASS: secret generated ($sec1)"
IPKG_INSTROOT='' sh ${SB_BACKEND_ROOT}/etc/uci-defaults/99-luci-singbox-ui \
	>"$log" 2>&1 || { echo "FAIL: secret rerun crashed"; cat "$log"; exit 1; }
sec2=$(uci -q get singbox-ui.clash_api.secret)
[ "$sec1" = "$sec2" ] || { echo "FAIL: secret changed on rerun ($sec1 → $sec2)"; exit 1; }
echo "  PASS: secret stable across reruns"

echo "-- cache migrates legacy enabled=0 + explicit /tmp path → storage=ram"
rm -f "$CONFIG"
cat >"$CONFIG" <<'EOF'
config cache 'cache'
	option enabled '0'
	option path '/tmp/singbox-ui-cache.db'
EOF
IPKG_INSTROOT='' sh ${SB_BACKEND_ROOT}/etc/uci-defaults/99-luci-singbox-ui \
	>"$log" 2>&1 || { echo "FAIL: cache migration crashed"; cat "$log"; exit 1; }
[ "$(uci -q get singbox-ui.cache.enabled 2>/dev/null)" = "1" ] \
	|| { echo "FAIL: cache enabled not flipped to 1"; uci show singbox-ui.cache; exit 1; }
echo "  PASS: cache enabled flipped"
[ "$(uci -q get singbox-ui.cache.storage 2>/dev/null)" = "ram" ] \
	|| { echo "FAIL: cache storage != ram"; uci show singbox-ui.cache; exit 1; }
echo "  PASS: cache storage=ram"
uci -q get singbox-ui.cache.path >/dev/null 2>&1 \
	&& { echo "FAIL: cache path should be absent after migration"; uci show singbox-ui.cache; exit 1; }
echo "  PASS: cache no path scalar"
[ "$(uci -q get singbox-ui.cache.store_fakeip 2>/dev/null)" = "1" ] \
	|| { echo "FAIL: cache store_fakeip != 1"; uci show singbox-ui.cache; exit 1; }
echo "  PASS: cache store_fakeip=1"

echo "-- cache leaves user-customised path alone (storage=custom)"
rm -f "$CONFIG"
cat >"$CONFIG" <<'EOF'
config cache 'cache'
	option enabled '1'
	option path '/srv/my.db'
EOF
IPKG_INSTROOT='' sh ${SB_BACKEND_ROOT}/etc/uci-defaults/99-luci-singbox-ui \
	>"$log" 2>&1 || { echo "FAIL: cache custom migration crashed"; cat "$log"; exit 1; }
[ "$(uci -q get singbox-ui.cache.storage 2>/dev/null)" = "custom" ] \
	|| { echo "FAIL: custom storage != custom"; uci show singbox-ui.cache; exit 1; }
echo "  PASS: custom storage"
[ "$(uci -q get singbox-ui.cache.path 2>/dev/null)" = "/srv/my.db" ] \
	|| { echo "FAIL: custom path not preserved"; uci show singbox-ui.cache; exit 1; }
echo "  PASS: custom path preserved"

echo "-- cache: user-explicit-disable + custom path preserved (enabled stays 0)"
rm -f "$CONFIG"
cat >"$CONFIG" <<'EOF'
config cache 'cache'
	option enabled '0'
	option path '/srv/explicit.db'
EOF
IPKG_INSTROOT='' sh ${SB_BACKEND_ROOT}/etc/uci-defaults/99-luci-singbox-ui \
	>"$log" 2>&1 || { echo "FAIL: explicit-disable migration crashed"; cat "$log"; exit 1; }
[ "$(uci -q get singbox-ui.cache.storage 2>/dev/null)" = "custom" ] \
	|| { echo "FAIL: explicit-disable storage != custom"; uci show singbox-ui.cache; exit 1; }
echo "  PASS: storage=custom"
[ "$(uci -q get singbox-ui.cache.path 2>/dev/null)" = "/srv/explicit.db" ] \
	|| { echo "FAIL: explicit-disable path not preserved"; uci show singbox-ui.cache; exit 1; }
echo "  PASS: path preserved"
[ "$(uci -q get singbox-ui.cache.enabled 2>/dev/null)" = "0" ] \
	|| { echo "FAIL: explicit-disable enabled was flipped (should stay 0)"; uci show singbox-ui.cache; exit 1; }
echo "  PASS: enabled stays 0 (user-explicit-disable respected)"

echo "-- dns_in is created for upgrades that don't have it"
rm -f "$CONFIG"
cat >"$CONFIG" <<'EOF'
config inbound 'tproxy_in'
	option enabled '1'
	option protocol 'tproxy'
	option listen_port '7893'
EOF
IPKG_INSTROOT='' sh ${SB_BACKEND_ROOT}/etc/uci-defaults/99-luci-singbox-ui \
	>"$log" 2>&1 || { echo "FAIL: dns_in creation crashed"; cat "$log"; exit 1; }
[ "$(uci -q get singbox-ui.dns_in 2>/dev/null)" = "inbound" ] \
	|| { echo "FAIL: dns_in section type != inbound"; uci show singbox-ui; exit 1; }
[ "$(uci get singbox-ui.dns_in.protocol)" = "direct" ] \
	|| { echo "FAIL: dns_in.protocol != direct"; exit 1; }
[ "$(uci get singbox-ui.dns_in.listen)" = "127.0.0.53" ] \
	|| { echo "FAIL: dns_in.listen != 127.0.0.53"; exit 1; }
[ "$(uci get singbox-ui.dns_in.listen_port)" = "53" ] \
	|| { echo "FAIL: dns_in.listen_port != 53"; exit 1; }
[ "$(uci get singbox-ui.dns_in.dns_listener)" = "1" ] \
	|| { echo "FAIL: dns_in.dns_listener != 1"; exit 1; }
[ "$(uci get singbox-ui.dns_in.network)" = "udp" ] \
	|| { echo "FAIL: dns_in.network != udp"; exit 1; }
[ "$(uci get singbox-ui.dns_in.enabled)" = "1" ] \
	|| { echo "FAIL: dns_in.enabled != 1"; exit 1; }
echo "  PASS: dns_in created with defaults"

echo "-- dns_in already present is left untouched"
rm -f "$CONFIG"
cat >"$CONFIG" <<'EOF'
config inbound 'dns_in'
	option enabled '1'
	option protocol 'direct'
	option listen '127.0.0.99'
	option listen_port '53'
	option dns_listener '1'
EOF
IPKG_INSTROOT='' sh ${SB_BACKEND_ROOT}/etc/uci-defaults/99-luci-singbox-ui \
	>"$log" 2>&1 || { echo "FAIL: dns_in preserve crashed"; cat "$log"; exit 1; }
[ "$(uci get singbox-ui.dns_in.listen)" = "127.0.0.99" ] \
	|| { echo "FAIL: dns_in.listen was overwritten (expected 127.0.0.99)"; exit 1; }
echo "  PASS: dns_in preserved (not overwritten)"

echo "-- extra_json is stripped from inbound/outbound sections"
rm -f "$CONFIG"
cat >"$CONFIG" <<'EOF'
config inbound 'a'
	option protocol 'tproxy'
	option extra_json '{"sniff":true}'

config outbound 'b'
	option proxy_type 'constructor'
	option protocol 'vless'
	option extra_json '{"x":1}'
EOF
IPKG_INSTROOT='' sh ${SB_BACKEND_ROOT}/etc/uci-defaults/99-luci-singbox-ui \
	>"$log" 2>&1 || { echo "FAIL: purge_extra_json crashed"; cat "$log"; exit 1; }
uci -q get singbox-ui.a.extra_json >/dev/null 2>&1 \
	&& { echo "FAIL: extra_json should be absent from inbound 'a'"; uci show singbox-ui.a; exit 1; }
echo "  PASS: extra_json removed from inbound"
uci -q get singbox-ui.b.extra_json >/dev/null 2>&1 \
	&& { echo "FAIL: extra_json should be absent from outbound 'b'"; uci show singbox-ui.b; exit 1; }
echo "  PASS: extra_json removed from outbound"

echo "-- purge_inbound_mode_json: mode=json + inbound_json populated → disabled, options absent"
rm -f "$CONFIG"
cat >"$CONFIG" <<'EOF'
config inbound 'ib_json'
	option enabled '1'
	option protocol 'vless'
	option mode 'json'
	option inbound_json '{"type":"vless","tag":"vless-in","listen":"::","listen_port":1080}'
EOF
IPKG_INSTROOT='' sh ${SB_BACKEND_ROOT}/etc/uci-defaults/99-luci-singbox-ui \
	>"$log" 2>&1 || { echo "FAIL: purge_inbound_mode_json (json) crashed"; cat "$log"; exit 1; }
[ "$(uci -q get singbox-ui.ib_json.enabled 2>/dev/null)" = "0" ] \
	|| { echo "FAIL: mode=json inbound should be disabled after migration"; uci show singbox-ui.ib_json; exit 1; }
echo "  PASS: enabled='0' (mode=json section disabled)"
uci -q get singbox-ui.ib_json.mode >/dev/null 2>&1 \
	&& { echo "FAIL: mode option should be absent after migration"; uci show singbox-ui.ib_json; exit 1; }
echo "  PASS: mode absent"
uci -q get singbox-ui.ib_json.inbound_json >/dev/null 2>&1 \
	&& { echo "FAIL: inbound_json option should be absent after migration"; uci show singbox-ui.ib_json; exit 1; }
echo "  PASS: inbound_json absent"

echo "-- purge_inbound_mode_json: mode=constructor only → enabled unchanged, mode absent"
rm -f "$CONFIG"
cat >"$CONFIG" <<'EOF'
config inbound 'ib_ctor'
	option enabled '1'
	option protocol 'tproxy'
	option mode 'constructor'
	option listen_port '7893'
EOF
IPKG_INSTROOT='' sh ${SB_BACKEND_ROOT}/etc/uci-defaults/99-luci-singbox-ui \
	>"$log" 2>&1 || { echo "FAIL: purge_inbound_mode_json (constructor) crashed"; cat "$log"; exit 1; }
[ "$(uci -q get singbox-ui.ib_ctor.enabled 2>/dev/null)" = "1" ] \
	|| { echo "FAIL: mode=constructor inbound enabled should stay 1"; uci show singbox-ui.ib_ctor; exit 1; }
echo "  PASS: enabled='1' (unchanged)"
uci -q get singbox-ui.ib_ctor.mode >/dev/null 2>&1 \
	&& { echo "FAIL: mode option should be absent after migration"; uci show singbox-ui.ib_ctor; exit 1; }
echo "  PASS: mode absent"

echo "-- migrate_outbound_type: proxy_type=constructor + protocol=vless → type=vless"
rm -f "$CONFIG"
cat >"$CONFIG" <<'EOF'
config outbound 'ob_ctor'
	option enabled '1'
	option proxy_type 'constructor'
	option protocol 'vless'
	option server 'v.example.com'
	option server_port '443'
EOF
IPKG_INSTROOT='' sh ${SB_BACKEND_ROOT}/etc/uci-defaults/99-luci-singbox-ui \
	>"$log" 2>&1 || { echo "FAIL: migrate_outbound_type (constructor+vless) crashed"; cat "$log"; exit 1; }
[ "$(uci -q get singbox-ui.ob_ctor.type 2>/dev/null)" = "vless" ] \
	|| { echo "FAIL: expected type=vless after migration"; uci show singbox-ui.ob_ctor; exit 1; }
echo "  PASS: type=vless"
uci -q get singbox-ui.ob_ctor.proxy_type >/dev/null 2>&1 \
	&& { echo "FAIL: proxy_type should be absent after migration"; uci show singbox-ui.ob_ctor; exit 1; }
echo "  PASS: proxy_type absent"
uci -q get singbox-ui.ob_ctor.protocol >/dev/null 2>&1 \
	&& { echo "FAIL: protocol should be absent after migration"; uci show singbox-ui.ob_ctor; exit 1; }
echo "  PASS: protocol absent"

echo "-- migrate_outbound_type: proxy_type=url/subscription → type=<same>"
for _pt in url subscription; do
	rm -f "$CONFIG"
	cat >"$CONFIG" <<EOF
config outbound 'ob_${_pt}'
	option enabled '1'
	option proxy_type '${_pt}'
EOF
	IPKG_INSTROOT='' sh ${SB_BACKEND_ROOT}/etc/uci-defaults/99-luci-singbox-ui \
		>"$log" 2>&1 || { echo "FAIL: migrate_outbound_type (${_pt}) crashed"; cat "$log"; exit 1; }
	_got=$(uci -q get "singbox-ui.ob_${_pt}.type" 2>/dev/null)
	[ "$_got" = "$_pt" ] \
		|| { echo "FAIL: expected type=${_pt}, got '${_got}'"; uci show "singbox-ui.ob_${_pt}"; exit 1; }
	echo "  PASS: type=${_pt}"
	uci -q get "singbox-ui.ob_${_pt}.proxy_type" >/dev/null 2>&1 \
		&& { echo "FAIL: proxy_type should be absent (${_pt})"; uci show "singbox-ui.ob_${_pt}"; exit 1; }
	echo "  PASS: proxy_type absent (${_pt})"
done

echo "-- migrate_outbound_type + E2 drop: proxy_type=interface → type=interface → deleted"
rm -f "$CONFIG"
cat >"$CONFIG" <<'EOF'
config outbound 'ob_interface'
	option enabled '1'
	option proxy_type 'interface'
EOF
IPKG_INSTROOT='' sh ${SB_BACKEND_ROOT}/etc/uci-defaults/99-luci-singbox-ui \
	>"$log" 2>&1 || { echo "FAIL: migrate (interface) crashed"; cat "$log"; exit 1; }
uci -q get singbox-ui.ob_interface >/dev/null 2>&1 \
	&& { echo "FAIL: ob_interface should be deleted by E2 Migration B"; uci show "singbox-ui.ob_interface"; exit 1; }
echo "  PASS: ob_interface deleted (E2 Migration B)"

echo "-- migrate_outbound_type: proxy_type=json → enabled=0, proxy_type absent, proxy_json absent"
rm -f "$CONFIG"
cat >"$CONFIG" <<'EOF'
config outbound 'ob_json'
	option enabled '1'
	option proxy_type 'json'
	option proxy_json '{"type":"vless","tag":"x"}'
EOF
IPKG_INSTROOT='' sh ${SB_BACKEND_ROOT}/etc/uci-defaults/99-luci-singbox-ui \
	>"$log" 2>&1 || { echo "FAIL: migrate_outbound_type (json) crashed"; cat "$log"; exit 1; }
[ "$(uci -q get singbox-ui.ob_json.enabled 2>/dev/null)" = "0" ] \
	|| { echo "FAIL: proxy_type=json outbound should be disabled after migration"; uci show singbox-ui.ob_json; exit 1; }
echo "  PASS: enabled=0 (json outbound disabled)"
uci -q get singbox-ui.ob_json.proxy_type >/dev/null 2>&1 \
	&& { echo "FAIL: proxy_type should be absent after migration"; uci show singbox-ui.ob_json; exit 1; }
echo "  PASS: proxy_type absent"
uci -q get singbox-ui.ob_json.proxy_json >/dev/null 2>&1 \
	&& { echo "FAIL: proxy_json should be absent after migration"; uci show singbox-ui.ob_json; exit 1; }
echo "  PASS: proxy_json absent"

# ---------------------------------------------------------------------------
# S1-7 — section enumeration robust to '.'/'=' in option VALUES (refactor gate).
# migrate_rename_e2_keys / migrate_drop_removed_protocols enumerate sections;
# the enumeration was unified from `awk -F'[.=]'` onto the file's standard
# `sed -n 's/^singbox-ui\.\([^.]*\)=<type>$/\1/p'` idiom. This is a pure
# refactor: it must PASS identically before and after the switch. The fixture's
# SIBLING option value 'a=b.c=d' (contains both '.' and '=') is the point —
# neither idiom may be derailed by it (option-value lines never end in
# =inbound/=outbound, so they are never iterated), and it must survive byte-for-
# byte. If this flips to FAIL the rewrite changed behaviour. (A section id with
# '.'/'=' — the only input that distinguishes the two idioms — cannot be created
# via uci, so there is no honest red case to assert here.)
# ---------------------------------------------------------------------------
echo "-- S1-7: section enumeration robust to '.'/'=' in option values (refactor gate)"
rm -f "$CONFIG"
cat >"$CONFIG" <<'EOF'
config inbound 'edge_in'
	option enabled '1'
	option protocol 'tproxy'
	option transport 'ws'
	option server_password 'a=b.c=d'
EOF
IPKG_INSTROOT='' sh ${SB_BACKEND_ROOT}/etc/uci-defaults/99-luci-singbox-ui \
	>"$log" 2>&1 || { echo "FAIL: S1-7 migration crashed"; cat "$log"; exit 1; }
# migrate_rename_e2_keys renamed transport → transport_type: proves the inbound
# section WAS enumerated despite the '.'/'='-bearing sibling value.
[ "$(uci -q get singbox-ui.edge_in.transport_type 2>/dev/null)" = "ws" ] \
	|| { echo "FAIL: S1-7 transport not renamed"; uci show singbox-ui.edge_in; exit 1; }
echo "  PASS: transport renamed (section enumerated)"
uci -q get singbox-ui.edge_in.transport >/dev/null 2>&1 \
	&& { echo "FAIL: S1-7 old transport key not removed"; uci show singbox-ui.edge_in; exit 1; }
echo "  PASS: old transport key removed"
[ "$(uci -q get singbox-ui.edge_in.server_password 2>/dev/null)" = "a=b.c=d" ] \
	|| { echo "FAIL: S1-7 sibling option value with '.'/'=' was mangled"; uci show singbox-ui.edge_in; exit 1; }
echo "  PASS: S1-7 enumeration robust to '.'/'=' in option values"

# ---------------------------------------------------------------------------
# Phase C2.1.2 — schema_version sentinel + idempotent re-run.
# After any successful migration run, _meta.schema_version is set to the
# script's CURRENT_SCHEMA. Re-running on the same config is a clean no-op
# (sentinel doesn't drift, no crash).
# ---------------------------------------------------------------------------
echo "-- C2.1.2: schema_version sentinel set + idempotent re-run"
ver=$(uci -q get singbox-ui._meta.schema_version 2>/dev/null || echo 0)
[ "$ver" -ge 1 ] 2>/dev/null \
    || { echo "FAIL: _meta.schema_version not set (got '$ver')"; uci show singbox-ui._meta 2>/dev/null; exit 1; }
echo "  PASS: _meta.schema_version=$ver"

IPKG_INSTROOT='' sh ${SB_BACKEND_ROOT}/etc/uci-defaults/99-luci-singbox-ui \
    >"$log" 2>&1 || { echo "FAIL: re-run crashed"; cat "$log"; exit 1; }
ver2=$(uci -q get singbox-ui._meta.schema_version 2>/dev/null || echo 0)
[ "$ver" = "$ver2" ] \
    || { echo "FAIL: schema_version drifted on re-run: $ver -> $ver2"; exit 1; }
echo "  PASS: migration is idempotent (schema_version stable on re-run)"

# ---------------------------------------------------------------------------
# Phase C2.1.3 — exactly one `uci commit singbox-ui` in the migration script.
# All migrations must be in-memory edits; the single commit at the end is
# crash-safe (no partial-state UCI files if SIGKILL hits mid-migration).
# File-grep is more robust than runtime instrumentation against this build
# of uci/busybox.
# ---------------------------------------------------------------------------
echo "-- C2.1.3: single uci commit in migration script"
commits_in_file=$(grep -Ec '^[[:space:]]*uci[[:space:]]+(-q[[:space:]]+)?commit[[:space:]]+singbox-ui' \
    ${SB_BACKEND_ROOT}/etc/uci-defaults/99-luci-singbox-ui)
[ "$commits_in_file" -eq 1 ] \
    || { echo "FAIL: expected exactly 1 'uci commit singbox-ui' in script, got $commits_in_file"; exit 1; }
echo "  PASS: single 'uci commit singbox-ui' in script ($commits_in_file)"

# ---------------------------------------------------------------------------
# Phase C2.1.2 — fresh install (no existing config) gets _meta initialised.
# ---------------------------------------------------------------------------
echo "-- C2.1.2: fresh install (no existing config) initialises _meta"
rm -f "$CONFIG"
touch "$CONFIG"
IPKG_INSTROOT='' sh ${SB_BACKEND_ROOT}/etc/uci-defaults/99-luci-singbox-ui \
    >"$log" 2>&1 || { echo "FAIL: fresh-install migration crashed"; cat "$log"; exit 1; }
ver_fresh=$(uci -q get singbox-ui._meta.schema_version 2>/dev/null || echo 0)
[ "$ver_fresh" -ge 1 ] 2>/dev/null \
    || { echo "FAIL: fresh install did not set _meta.schema_version (got '$ver_fresh')"; exit 1; }
echo "  PASS: fresh install sets _meta.schema_version=$ver_fresh"

# ---------------------------------------------------------------------------
# Phase C2.1.2 — install already at CURRENT_SCHEMA: script exits early.
# Seed schema_version=999 (well above any real CURRENT_SCHEMA); verify the
# script does NOT touch the data (no legacy migrations fire, no commits).
# ---------------------------------------------------------------------------
echo "-- C2.1.2: install at-or-above CURRENT_SCHEMA exits early"
rm -f "$CONFIG"
cat >"$CONFIG" <<'EOF'
config _meta '_meta'
	option schema_version '999'

config fakeip 'fakeip'
	option enabled '1'
	list inet4_range '198.18.0.0/15'
	list inet4_range '198.30.0.0/15'
EOF
IPKG_INSTROOT='' sh ${SB_BACKEND_ROOT}/etc/uci-defaults/99-luci-singbox-ui \
    >"$log" 2>&1 || { echo "FAIL: future-schema rerun crashed"; cat "$log"; exit 1; }
# fakeip should NOT have been migrated to dns_server (it should still be a
# fakeip section with a list inet4_range), proving early-exit fired.
sec_type=$(uci -q get singbox-ui.fakeip 2>/dev/null || echo '')
[ "$sec_type" = "fakeip" ] \
    || { echo "FAIL: early-exit failed — fakeip section type is '$sec_type' (expected 'fakeip')"; uci show singbox-ui; exit 1; }
echo "  PASS: schema_version >= CURRENT short-circuits all migrations"
ver_kept=$(uci -q get singbox-ui._meta.schema_version 2>/dev/null || echo 0)
[ "$ver_kept" = "999" ] \
    || { echo "FAIL: schema_version was rewritten from 999 to '$ver_kept'"; exit 1; }
echo "  PASS: schema_version (999) preserved on early-exit"

echo "OK"
