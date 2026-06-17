#!/bin/sh
# tests/test_nftables_apply_lock.sh
# S1-4: two concurrent `apply` runs must serialize on a skip-on-contention lock —
# exactly one wins and applies, the other is cleanly skipped (no crash), and the
# lock dir is released afterwards (no stale lock). The lock is a *directory*
# (fs.mkdir is the atomic primitive; fs.open(path,"x") does not create in ucode).
set -e
. "$(dirname "$0")/../lib/sb_helpers.sh"

if command -v ucode >/dev/null 2>&1; then
	UCODE_BIN=ucode
	UCODE_LIB_FLAGS="-L ${UCODE_APP_LIB_DIR:-$PWD/${SB_LIB}}"
elif [ -x "${UCODE_BIN:-}" ] && [ -d "${UCODE_STUB_DIR:-}" ]; then
	UCODE_LIB_FLAGS="-L $UCODE_STUB_DIR -L ${UCODE_APP_LIB_DIR:-$PWD/${SB_LIB}}"
else
	echo "SKIP: ucode not available"; exit 0
fi

SCRIPT=$PWD/${SB_SHARE}/nftables.uc
TMPDIR=$(mktemp -d)
mkdir -p /tmp/singbox-ui
trap 'rm -rf "$TMPDIR"; rm -rf /tmp/singbox-ui/.apply.lock' EXIT

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

echo "-- S1-4: a pre-existing fresh lock (with a live owner) makes apply refuse"
mkdir -p /tmp/singbox-ui/.apply.lock
# SEC-3: an owner-LESS lock dir is now treated as immediately stale (a healthy
# holder always writes its owner synchronously), so a real contention test must
# stamp a non-empty owner AND a fresh mtime — otherwise apply would (correctly)
# reclaim it. This proves a genuinely-held lock still blocks.
printf 'deadbeefcafef00d' > /tmp/singbox-ui/.apply.lock/owner
touch /tmp/singbox-ui/.apply.lock /tmp/singbox-ui/.apply.lock/owner
# Run under `if` so `set -e` does NOT abort on the (expected) non-zero exit.
# shellcheck disable=SC2086
if PATH="$TMPDIR/bin:$PATH" UCI_CONFIG_DIR="$UCI" \
		"$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" apply >/dev/null 2>"$TMPDIR/locked.err"; then
	rc=0
else
	rc=$?
fi
rm -rf /tmp/singbox-ui/.apply.lock
[ "$rc" -ne 0 ] \
	|| { echo "FAIL: S1-4 apply ignored a live-owner lock (no serialization)"; exit 1; }
grep -qi 'another apply\|lock' "$TMPDIR/locked.err" \
	|| { echo "FAIL: S1-4 expected a lock-contention message"; cat "$TMPDIR/locked.err"; exit 1; }
echo "  PASS: S1-4 existing live-owner lock blocks apply"

echo "-- SEC-3: an owner-less lock past the grace is reclaimed before the 60s TTL"
# A crash between mkdir(APPLY_LOCK) and the owner write leaves a lock dir with no
# owner token. The old guard treated only mtime>60s as stale, so this owner-less
# lock wedged apply for the full TTL. SEC-3 reclaims it once it is past a short
# grace (a live holder writes+verifies its owner within ms, so a grace-aged
# owner-less dir can only be a crash). Backdate ~30s — past the 5s grace, well
# UNDER the 60s TTL — so success here proves reclaim is owner-driven, not TTL.
mkdir -p /tmp/singbox-ui/.apply.lock     # NO owner file inside
PAST=$(( $(date +%s) - 30 ))
if STAMP=$(date -d "@$PAST" +%Y%m%d%H%M.%S 2>/dev/null) && [ -n "$STAMP" ]; then
	touch -t "$STAMP" /tmp/singbox-ui/.apply.lock 2>/dev/null \
		|| touch -t 202001010000 /tmp/singbox-ui/.apply.lock
else
	# date -d @epoch unsupported: fall back to a far-past stamp. Still owner-less,
	# still proves the owner-less reclaim path (this stamp is also past the TTL).
	touch -t 202001010000 /tmp/singbox-ui/.apply.lock
fi
# shellcheck disable=SC2086
if PATH="$TMPDIR/bin:$PATH" UCI_CONFIG_DIR="$UCI" \
		"$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" apply >/dev/null 2>"$TMPDIR/noowner.err"; then
	rc=0
else
	rc=$?
fi
[ "$rc" -eq 0 ] \
	|| { echo "FAIL: SEC-3 owner-less lock not reclaimed (apply rc=$rc)"; cat "$TMPDIR/noowner.err"; exit 1; }
[ ! -e /tmp/singbox-ui/.apply.lock ] \
	|| { echo "FAIL: SEC-3 lock not released after owner-less reclaim"; exit 1; }
echo "  PASS: SEC-3 owner-less lock reclaimed and released"

echo "-- SEC-3: a fresh owner-less lock WITHIN the grace is NOT yet reclaimed"
# Symmetric guard: a just-created owner-less lock (mtime=now, inside the 5s grace)
# must NOT be stolen — this is the window protecting a concurrent winner whose
# owner write is still in flight. apply must refuse (rc!=0), proving the grace
# closes the two-winners race the naive 'no owner => steal' would have opened.
mkdir -p /tmp/singbox-ui/.apply.lock     # fresh mtime=now, NO owner file
# shellcheck disable=SC2086
if PATH="$TMPDIR/bin:$PATH" UCI_CONFIG_DIR="$UCI" \
		"$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" apply >/dev/null 2>"$TMPDIR/grace.err"; then
	rc=0
else
	rc=$?
fi
rm -rf /tmp/singbox-ui/.apply.lock
[ "$rc" -ne 0 ] \
	|| { echo "FAIL: SEC-3 fresh owner-less lock stolen inside the grace (two-winners race open)"; cat "$TMPDIR/grace.err"; exit 1; }
echo "  PASS: SEC-3 in-grace owner-less lock is held (race closed)"

echo "-- S5.1/10.3: a stale (>60s) lock is reclaimed; apply succeeds and frees it"
mkdir -p /tmp/singbox-ui/.apply.lock
# Backdate the lock dir mtime well past the 60s TTL. touch -t is portable across
# busybox (VM) and coreutils (host); '202001010000' is 2020-01-01, always stale.
touch -t 202001010000 /tmp/singbox-ui/.apply.lock
# shellcheck disable=SC2086
if PATH="$TMPDIR/bin:$PATH" UCI_CONFIG_DIR="$UCI" \
		"$UCODE_BIN" $UCODE_LIB_FLAGS "$SCRIPT" apply >/dev/null 2>"$TMPDIR/stale.err"; then
	rc=0
else
	rc=$?
fi
[ "$rc" -eq 0 ] \
	|| { echo "FAIL: S5.1 stale lock not reclaimed (apply rc=$rc)"; cat "$TMPDIR/stale.err"; exit 1; }
[ ! -e /tmp/singbox-ui/.apply.lock ] \
	|| { echo "FAIL: S5.1 lock not released after reclaimed apply"; exit 1; }
echo "  PASS: S5.1 stale lock reclaimed and released"

echo "OK"
