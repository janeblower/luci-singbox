#!/bin/sh
# tests/test_nftables_ctmark.sh
# Structural invariants of the ctmark ruleset. Anchored finer than
# test_nftables_emit.sh so accidental regressions (e.g., dropping the
# fast-path, switching back to meta mark in decisions) are caught.
set -e

SCRIPT=luci-app-singbox-ui/root/usr/share/singbox-ui/nftables.uc

if command -v ucode >/dev/null 2>&1; then
	UCODE_BIN=ucode
	UCODE_LIB_FLAGS="-L ${UCODE_APP_LIB_DIR:-$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/lib}"
elif [ -x "${UCODE_BIN:-}" ] && [ -d "${UCODE_STUB_DIR:-}" ]; then
	UCODE_LIB_FLAGS="-L $UCODE_STUB_DIR -L ${UCODE_APP_LIB_DIR:-$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/lib}"
else
	echo "SKIP: ucode not available"; exit 0
fi

emit() {
	"$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" emit "$@"
}

echo "-- t_fakeip_named_set"
out=$(emit 7895 198.18.0.0/15 fc00::/18 br-lan)
echo "$out" | grep -q 'set fakeip4 {' || { echo FAIL fakeip4; exit 1; }
echo "$out" | grep -q 'set fakeip6 {' || { echo FAIL fakeip6; exit 1; }
# Literal {198.18...} in a daddr expression would mean the set never moved to named form.
echo "$out" | grep -q 'daddr { 198.18' && { echo FAIL literal fakeip4 still present; exit 1; }
:

echo "-- t_wan_ifaces_named_set"
echo "$out" | grep -q 'set wan_ifaces {' || { echo FAIL wan_ifaces; exit 1; }
# Right after the wan_ifaces set declaration, the next line should be `type ifname`.
echo "$out" | awk '/set wan_ifaces/{f=1; next} f && /type/{print; exit}' \
	| grep -q 'type ifname' || { echo FAIL type ifname; exit 1; }
# Literal iifname { "x", "y" } in the chain body means we did not move to named form.
echo "$out" | grep 'iifname' | grep -q '{ "' && { echo FAIL literal iifname still present; exit 1; }
:

echo "-- t_socket_transparent_fast_path_first"
# Within the prerouting chain, the FIRST real rule must be the fast-path.
echo "$out" | awk '
	/chain prerouting \{/ {in_chain=1; next}
	in_chain && /^\t\ttype/ {next}
	in_chain && /^[^\t]/ {exit}
	in_chain && /^\t\t[^[:space:]]/ {print; exit}
' | grep -q 'socket transparent 1' || { echo FAIL fast-path not first; exit 1; }

echo "-- t_ct_mark_or_assignment"
n=$(echo "$out" | grep -c 'ct mark set ct mark or 0x1')
# Baseline emit (no ruleset files): fakeip4 + fakeip6 = 2 decisions.
[ "$n" -ge 2 ] || { echo "FAIL: expected >=2 ct mark or decisions, got $n"; exit 1; }
# No decision rule (line containing 'ct state new') may write meta mark.
echo "$out" | grep 'ct state new' | grep -q 'meta mark set' \
	&& { echo "FAIL: decision uses meta mark"; exit 1; }
:

echo "-- t_mark_restore_twice"
n=$(echo "$out" | grep -c '^[[:space:]]*meta mark set ct mark$')
[ "$n" -eq 2 ] || { echo "FAIL: expected exactly 2 mark-restore lines, got $n"; exit 1; }

echo "-- t_tproxy_uses_and_mask"
echo "$out" | grep -q 'meta mark and 0x1 == 0x1' || { echo FAIL and-mask; exit 1; }
# Exact-equality match (the old form): 'meta mark 0x1' followed immediately by meta l4proto.
echo "$out" | grep -q 'meta mark 0x1 meta l4proto' && { echo FAIL: exact equality still present; exit 1; }
:

echo "-- t_custom_fwmark_propagates"
out2=$(emit 7895 198.18.0.0/15 fc00::/18 br-lan 0x100 0xff00 0)
echo "$out2" | grep -q 'ct mark set ct mark or 0x100' \
	|| { echo FAIL custom mark; exit 1; }
echo "$out2" | grep -q 'meta mark and 0xff00 == 0x100' \
	|| { echo FAIL custom mask; exit 1; }
# Fast-path: assigns mark & mask = 0x100 & 0xff00 = 0x100.
echo "$out2" | grep -q 'socket transparent 1 meta mark set 0x100' \
	|| { echo FAIL fast-path mark; exit 1; }

echo "-- t_router_output_chain"
out3=$(emit 7895 198.18.0.0/15 fc00::/18 br-lan 0x1 0x1 1)
echo "$out3" | grep -q 'chain output {' || { echo FAIL output chain missing; exit 1; }
echo "$out3" | grep -q 'type route hook output priority mangle' \
	|| { echo FAIL output hook; exit 1; }

out4=$(emit 7895 198.18.0.0/15 fc00::/18 br-lan 0x1 0x1 0)
echo "$out4" | grep -q 'chain output {' \
	&& { echo FAIL output chain present when disabled; exit 1; }
:

echo "-- t_invalid_fwmark_falls_back"
out5=$(emit 7895 198.18.0.0/15 fc00::/18 br-lan xyz 0 0 2>&1)
echo "$out5" | grep -q 'ct mark set ct mark or 0x1' \
	|| { echo FAIL fallback not 0x1; exit 1; }

echo "-- t_rs_rule_uses_ct_mark — regression guard for the original bug"
# Drop a rs_*.json with one v4 CIDR; assert the emitted decision rule
# uses ct mark, not meta mark.
mkdir -p /tmp/singbox-ui
cat >/tmp/singbox-ui/rs_ctmarktest.json <<EOF
{"rules":[{"ip_cidr":["8.8.8.0/24"],"network":"","port_range":[]}]}
EOF
out6=$(emit 7895 198.18.0.0/15 fc00::/18 br-lan)
rm -f /tmp/singbox-ui/rs_ctmarktest.json
echo "$out6" | grep '@rs_ctmarktest_0_v4' | grep -q 'ct mark set ct mark or' \
	|| { echo "FAIL: rs_* decision not using ct mark"; exit 1; }
echo "$out6" | grep '@rs_ctmarktest_0_v4' | grep -q 'meta mark set' \
	&& { echo "FAIL: rs_* decision still writes meta mark"; exit 1; }
:

echo "OK: nftables ctmark structural tests passed"
