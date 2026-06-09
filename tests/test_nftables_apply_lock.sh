#!/bin/sh
# tests/test_nftables_apply_lock.sh
# S1-4: two concurrent `apply` runs must serialize on a skip-on-contention lock —
# exactly one wins and applies, the other is cleanly skipped (no crash), and the
# lock file is released afterwards (no stale lock).
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
TMPDIR=$(mktemp -d)
mkdir -p /tmp/singbox-ui
trap 'rm -rf "$TMPDIR"; rm -f /tmp/singbox-ui/.apply.lock' EXIT

# Slow nft so the two applies overlap in time.
mkdir -p "$TMPDIR/bin"
cat >"$TMPDIR/bin/nft" <<'EOF'
#!/bin/sh
if [ "$1" = "-f" ]; then sleep 1; cat "$2" >/dev/null; exit 0; fi
exit 0
EOF
chmod +x "$TMPDIR/bin/nft"

UCI="$TMPDIR/uci"; mkdir -p "$UCI"
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

run_apply() {
	# shellcheck disable=SC2086
	PATH="$TMPDIR/bin:$PATH" UCI_CONFIG_DIR="$UCI" \
		"$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" apply >/dev/null 2>"$1"
}

echo "-- S1-4: two concurrent applies serialize — one runs, one is skipped"
run_apply "$TMPDIR/a.err" &
p1=$!
run_apply "$TMPDIR/b.err" &
p2=$!
# `set -e`-safe: a non-zero `wait` must not abort before we record rc; capture
# it as the exit of an `if` so the script keeps running and the assertions fire.
if wait "$p1"; then rc1=0; else rc1=$?; fi
if wait "$p2"; then rc2=0; else rc2=$?; fi
# neither crashed (signal => rc >= 128)
[ "$rc1" -lt 128 ] && [ "$rc2" -lt 128 ] || { echo "FAIL: an apply crashed (rc1=$rc1 rc2=$rc2)"; cat "$TMPDIR/a.err" "$TMPDIR/b.err"; exit 1; }
# exactly one acquired the lock and applied (0); the other was skipped (1)
[ $(( rc1 + rc2 )) -eq 1 ] || { echo "FAIL: expected exactly one apply to win and one to be skipped, got rc1=$rc1 rc2=$rc2"; cat "$TMPDIR/a.err" "$TMPDIR/b.err"; exit 1; }
[ ! -e /tmp/singbox-ui/.apply.lock ] || { echo "FAIL: S1-4 stale lock left behind"; exit 1; }
echo "  PASS: S1-4 concurrent applies serialized (one ran, one skipped), lock released"

echo "-- S1-4: a pre-existing fresh lock makes apply refuse (no race window)"
: > /tmp/singbox-ui/.apply.lock
# Run under `if` so `set -e` does NOT abort on the (expected, post-fix)
# non-zero exit — that is the whole point of the assertion below.
# shellcheck disable=SC2086
if PATH="$TMPDIR/bin:$PATH" UCI_CONFIG_DIR="$UCI" \
		"$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" apply >/dev/null 2>"$TMPDIR/locked.err"; then
	rc=0
else
	rc=$?
fi
rm -f /tmp/singbox-ui/.apply.lock
[ "$rc" -ne 0 ] \
	|| { echo "FAIL: S1-4 apply ignored an existing lock (no serialization)"; exit 1; }
grep -qi 'another apply\|lock' "$TMPDIR/locked.err" \
	|| { echo "FAIL: S1-4 expected a lock-contention message"; cat "$TMPDIR/locked.err"; exit 1; }
echo "  PASS: S1-4 existing lock blocks apply"

echo "OK"
