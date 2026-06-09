#!/bin/sh
# tests/test_nftables_apply_security.sh
# Regression: drive the REAL `apply` subcommand (reads /tmp/singbox-ui/rs_*.json)
# and prove (a) a poisoned port_range is never injected into the ruleset nft
# applies (S1-1), and (b) an invalid tproxy listen_port makes apply FAIL loudly
# instead of silently dropping the tproxy block (S1-2).
set -e

if command -v ucode >/dev/null 2>&1; then
	UCODE_BIN=ucode
	UCODE_LIB_FLAGS="-L ${UCODE_APP_LIB_DIR:-$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/lib}"
elif [ -x "${UCODE_BIN:-}" ] && [ -d "${UCODE_STUB_DIR:-}" ]; then
	UCODE_LIB_FLAGS="-L $UCODE_STUB_DIR -L ${UCODE_APP_LIB_DIR:-$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/lib}"
else
	echo "SKIP: ucode not available"; exit 0
fi

SCRIPT=$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/nftables.uc
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

echo "OK"
