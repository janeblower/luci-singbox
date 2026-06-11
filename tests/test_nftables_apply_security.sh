#!/bin/sh
# tests/test_nftables_apply_security.sh
# Regression: drive the REAL `apply` subcommand (reads /tmp/singbox-ui/rs_*.json)
# and prove (a) a poisoned port_range is never injected into the ruleset nft
# applies (S1-1), and (b) an invalid tproxy listen_port makes apply FAIL loudly
# instead of silently dropping the tproxy block (S1-2).
set -e

if command -v ucode >/dev/null 2>&1; then
	UCODE_BIN=ucode
	UCODE_LIB_FLAGS="-L ${UCODE_APP_LIB_DIR:-$PWD/luci-singbox-ui/root/usr/share/singbox-ui/lib}"
elif [ -x "${UCODE_BIN:-}" ] && [ -d "${UCODE_STUB_DIR:-}" ]; then
	UCODE_LIB_FLAGS="-L $UCODE_STUB_DIR -L ${UCODE_APP_LIB_DIR:-$PWD/luci-singbox-ui/root/usr/share/singbox-ui/lib}"
else
	echo "SKIP: ucode not available"; exit 0
fi

SCRIPT=$PWD/luci-singbox-ui/root/usr/share/singbox-ui/nftables.uc
RS_DIR=/tmp/singbox-ui
TMPDIR=$(mktemp -d)
# Register cleanup IMMEDIATELY after mktemp, before any command that could fail
# under `set -e` (e.g. mkdir below) and otherwise leak the temp dir. RS_DIR is
# defined above so the trap can reference it.
trap 'rm -rf "$TMPDIR"; rm -f "$RS_DIR"/rs_aps_*.json' EXIT
mkdir -p "$RS_DIR"
rm -f "$RS_DIR"/rs_aps_*.json

# Stub nft that captures the applied ruleset to a file instead of touching the
# kernel. `nft -f <path>` is how cmd_apply applies; `nft delete table …` (argv)
# is the cleanup call — both must exit 0 here.
mkdir -p "$TMPDIR/bin"
cat >"$TMPDIR/bin/nft" <<EOF
#!/bin/sh
if [ "\$1" = "-f" ]; then cat "\$2" > "$TMPDIR/applied.nft"; exit 0; fi
exit 0
EOF
chmod +x "$TMPDIR/bin/nft"

# Minimal UCI: one enabled tproxy inbound + one fakeip dns_server so cmd_apply
# builds a ruleset instead of early-returning "table removed".
UCI="$TMPDIR/uci"
mkdir -p "$UCI"
cat >"$UCI/singbox-ui" <<'EOF'
config dns_server fakeip
	option type 'fakeip'
	option enabled '1'
	option inet4_range '198.18.0.0/15'
config inbound tp
	option protocol 'tproxy'
	option enabled '1'
	option nft_rules '1'
	option listen_port '7895'
	list interface 'br-lan'
EOF

apply() {
	# shellcheck disable=SC2086
	PATH="$TMPDIR/bin:$PATH" UCI_CONFIG_DIR="$UCI" \
		"$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" apply 2>"$TMPDIR/apply.err"
}

echo "-- S1-1 (apply path): poisoned port_range in a real rs_*.json is not injected"
cat >"$RS_DIR/rs_aps_inj.json" <<'JSON'
{ "rules": [ { "ip_cidr": "10.0.0.0/8", "network": "tcp", "port_range": "80 }; insert rule inet filter forward drop; #" } ] }
JSON
apply || { echo "FAIL: apply returned non-zero on a droppable port_range"; cat "$TMPDIR/apply.err"; exit 1; }
grep -q 'insert rule' "$TMPDIR/applied.nft" \
	&& { echo "FAIL: S1-1 injection reached the applied ruleset"; cat "$TMPDIR/applied.nft"; exit 1; }
grep -q 'dropping invalid port_range' "$TMPDIR/apply.err" \
	|| { echo "FAIL: S1-1 expected a drop log on stderr"; cat "$TMPDIR/apply.err"; exit 1; }
rm -f "$RS_DIR/rs_aps_inj.json"
echo "  PASS: S1-1 apply-path injection dropped + logged"

echo "-- S1-1 (apply path): out-of-range port_range '99999' is dropped, not applied"
# Passes the old [0-9]{1,5} regex but exceeds 65535; the kernel would reject the
# WHOLE `nft -f` ruleset. safe_port_range must drop it here like any bad token.
cat >"$RS_DIR/rs_aps_oor.json" <<'JSON'
{ "rules": [ { "ip_cidr": "10.0.0.0/8", "network": "tcp", "port_range": "99999" } ] }
JSON
apply || { echo "FAIL: apply returned non-zero on a droppable out-of-range port_range"; cat "$TMPDIR/apply.err"; exit 1; }
grep -q 'dport 99999' "$TMPDIR/applied.nft" \
	&& { echo "FAIL: S1-1 out-of-range port reached the applied ruleset"; cat "$TMPDIR/applied.nft"; exit 1; }
grep -q 'dropping invalid port_range' "$TMPDIR/apply.err" \
	|| { echo "FAIL: S1-1 expected a drop log on stderr for out-of-range port"; cat "$TMPDIR/apply.err"; exit 1; }
rm -f "$RS_DIR/rs_aps_oor.json"
echo "  PASS: S1-1 apply-path out-of-range port_range dropped + logged"

# ---- S1-PERF: apply (preloaded rs list) ≡ emit (internal load), byte-identical ----
# Task 8 made build_ruleset() take an optional preloaded `rules` list: the apply
# path now loads /tmp/singbox-ui/rs_*.json ONCE and threads it in, while emit
# still defaults to load_rs_rules() internally. This is a pure perf refactor —
# both code paths must produce a byte-for-byte identical ruleset for the same
# inputs. Characterize it by feeding ONE rs_*.json to both paths and diffing the
# full emitted ruleset (not a grep). The UCI mock above is still the valid config
# (tproxy port 7895, fakeip v4 198.18.0.0/15, iface br-lan, default mark/mask,
# no router-out) — the equivalent emit argv is `7895 198.18.0.0/15 "" br-lan`.
echo "-- S1-PERF (apply path): preloaded rs list yields the same ruleset as emit's internal load"
cat >"$RS_DIR/rs_aps_perf.json" <<'JSON'
{ "rules": [ { "ip_cidr": ["1.2.3.0/24"], "network": "tcp", "port_range": "80:443" } ] }
JSON
apply || { echo "FAIL: apply returned non-zero while building the S1-PERF ruleset"; cat "$TMPDIR/apply.err"; exit 1; }
cp "$TMPDIR/applied.nft" "$TMPDIR/perf-apply.nft"
# Same inputs through emit, which exercises build_ruleset's internal load_rs_rules().
# shellcheck disable=SC2086
"$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" emit 7895 "198.18.0.0/15" "" "br-lan" > "$TMPDIR/perf-emit.nft"
if ! cmp -s "$TMPDIR/perf-apply.nft" "$TMPDIR/perf-emit.nft"; then
	echo "FAIL: S1-PERF apply (preloaded rules) and emit (internal load) rulesets differ"
	diff -u "$TMPDIR/perf-emit.nft" "$TMPDIR/perf-apply.nft" || true
	exit 1
fi
# Sanity: the rs_* set actually made it in, so we diffed a non-trivial ruleset.
grep -q 'set rs_aps_perf_0_v4' "$TMPDIR/perf-apply.nft" \
	|| { echo "FAIL: S1-PERF expected rs_aps_perf set in the captured ruleset"; cat "$TMPDIR/perf-apply.nft"; exit 1; }
rm -f "$RS_DIR/rs_aps_perf.json"
echo "  PASS: S1-PERF preloaded-rules apply ≡ internal-load emit (byte-identical)"

echo "-- S1-2 (apply path): invalid tproxy listen_port makes apply FAIL, not silently blackhole"
cat >"$UCI/singbox-ui" <<'EOF'
config dns_server fakeip
	option type 'fakeip'
	option enabled '1'
	option inet4_range '198.18.0.0/15'
config inbound tp
	option protocol 'tproxy'
	option enabled '1'
	option nft_rules '1'
	option listen_port '99999'
	list interface 'br-lan'
EOF
if apply; then
	echo "FAIL: S1-2 apply returned 0 on an invalid tproxy port (silent blackhole)"
	cat "$TMPDIR/applied.nft" 2>/dev/null
	exit 1
fi
grep -qi 'invalid listen_port\|tproxy' "$TMPDIR/apply.err" \
	|| { echo "FAIL: S1-2 expected an error log about the bad tproxy port"; cat "$TMPDIR/apply.err"; exit 1; }
echo "  PASS: S1-2 invalid tproxy port surfaces an error"

echo "OK"
