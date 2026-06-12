#!/bin/sh
# tests/test_audit_4_1_cold_backoff.sh
#
# Regression for audit S4-1 / S4-5 / S4-6 (subscription.uc cold rule-set reload):
#
#   4.1 HIGH — a dead/404 remote nft rule-set is forever cold, which made
#       cmd_refresh issue a full stop+start `init.d reload` (dropping every live
#       proxy connection) on every cron cycle and still fail. The fix gates the
#       reload on a per-tag backoff sentinel under TMPDIR: a cold tag may trigger
#       a reload only when it has no sentinel or its update_interval has elapsed
#       since the last failed attempt. The sentinel is stamped after the
#       reload+poll for tags that stay cold, and cleared on a successful extract.
#       Warm tags must still NEVER trigger a reload.
#
#   4.5 LOW — wait_for_tags must not busy-spin if `sleep` is unforkable: it now
#       checks system()'s rc and bails on a non-zero return.
#
#   4.6 INFO — cache_extract_srs writes to a temp sibling and renames on success
#       so no 0-byte rs_*.raw is observable; a failed extract leaves no stray
#       file at the real path.
#
# Runs on host via the same env stubs as test_rs_cache_extract.sh
# (SINGBOX_INITD, SINGBOX_BBOLT_BIN, SINGBOX_RS_CACHE_WAIT, SINGBOX_NFT_APPLY).
set -e

if command -v ucode >/dev/null 2>&1; then
	UCODE_BIN=ucode
	UCODE_LIB_FLAGS="-L ${UCODE_APP_LIB_DIR:-$PWD/luci-singbox-ui/root/usr/share/singbox-ui/lib}"
elif [ -x "${UCODE_BIN:-}" ] && [ -d "${UCODE_STUB_DIR:-}" ]; then
	UCODE_LIB_FLAGS="-L $UCODE_STUB_DIR"
	[ -n "${UCODE_LIB_DIR:-}" ] && UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L $UCODE_LIB_DIR"
	UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L ${UCODE_APP_LIB_DIR:-$PWD/luci-singbox-ui/root/usr/share/singbox-ui/lib}"
else
	echo "SKIP: ucode not available"
	exit 0
fi

SUB_UC=luci-singbox-ui/root/usr/share/singbox-ui/subscription.uc
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export SINGBOX_TMPDIR="$TMPDIR/runtime"
mkdir -p "$SINGBOX_TMPDIR" "$TMPDIR/bin" "$TMPDIR/initd"

pass() { echo "  PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }
run_uc() {
	# shellcheck disable=SC2086
	UCI_CONFIG_DIR="$TMPDIR" "$UCODE_BIN" $UCODE_LIB_FLAGS "$SUB_UC" "$@"
}

# --- fake bbolt-client (same contract as test_rs_cache_extract.sh):
#     "<db> rule_set" lists $BBOLT_KNOWN; "-r <db> rule_set <tag>" emits a body
#     for a known tag else exits 1.
cat >"$TMPDIR/bin/bbolt-client" <<'EOF'
#!/bin/sh
known=" ${BBOLT_KNOWN:-} "
if [ "$1" = "-r" ]; then
	tag="$4"
	case "$known" in *" $tag "*) printf 'SRS\003FAKEBODY'; exit 0 ;; esac
	exit 1
fi
if [ "$2" = "rule_set" ]; then
	for t in ${BBOLT_KNOWN:-}; do echo "$t"; done
	exit 0
fi
exit 0
EOF
chmod +x "$TMPDIR/bin/bbolt-client"
export SINGBOX_BBOLT_BIN="$TMPDIR/bin/bbolt-client"

# --- fake sing-box decompile.
cat >"$TMPDIR/bin/sing-box" <<'EOF'
#!/bin/sh
out=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done
[ -n "$out" ] && printf '{"version":1,"rules":[{"ip_cidr":["1.2.3.0/24"]}]}' >"$out"
exit 0
EOF
chmod +x "$TMPDIR/bin/sing-box"
export SINGBOX="$TMPDIR/bin/sing-box"

# --- fake init.d that records every reload call.
cat >"$TMPDIR/initd/singbox-ui" <<'EOF'
#!/bin/sh
echo "reload-called $*" >>"$RELOAD_LOG"
EOF
chmod +x "$TMPDIR/initd/singbox-ui"
export SINGBOX_INITD="$TMPDIR/initd/singbox-ui"
export SINGBOX_NFT_APPLY="true"
export RELOAD_LOG="$TMPDIR/reload.log"
export PATH="$TMPDIR/bin:$PATH"
export SINGBOX_RS_CACHE_WAIT=1

count_reloads() {
	# grep -c exits 1 (and prints 0) on no match; capture only the count.
	n=$(grep -c reload-called "$RELOAD_LOG" 2>/dev/null) || true
	[ -n "$n" ] || n=0
	printf '%s' "$n"
}

# A dead remote rule-set: cache never lists it, update_interval is large so the
# backoff window is wide. With BBOLT_KNOWN empty the tag stays cold forever.
cat >"$TMPDIR/singbox-ui" <<'EOF'
config cache 'cache'
	option enabled '1'
config ruleset 'deadrs'
	option type 'remote'
	option url 'https://example.invalid/dead.srs'
	option nft_rules '1'
	option update_interval '86400'
EOF

# ============================================================
echo "-- 4.1: dead cold tag reloads ONCE, then backs off (no teardown loop)"
: >"$RELOAD_LOG"
# First refresh (cron path, no force): no sentinel yet → eligible → exactly one
# reload, still cold. Throttle assertions use the cron path on purpose — a UI
# force-refresh deliberately overrides the backoff (covered in the BUG2 block).
BBOLT_KNOWN="" run_uc refresh rulesets >/dev/null 2>&1 || true
[ "$(count_reloads)" -eq 1 ] || fail "first cold refresh should reload exactly once (got $(count_reloads))"
[ -f "$SINGBOX_TMPDIR/.rs_cold_deadrs.attempt" ] || fail "backoff sentinel not stamped for dead tag"
pass "first cold refresh reloads once and stamps sentinel"

# Second + third refresh within the backoff window: tag still cold but its
# update_interval (1 day) has NOT elapsed → must NOT reload again.
BBOLT_KNOWN="" run_uc refresh rulesets >/dev/null 2>&1 || true
BBOLT_KNOWN="" run_uc refresh rulesets >/dev/null 2>&1 || true
[ "$(count_reloads)" -eq 1 ] || fail "dead tag re-reloaded inside backoff window (got $(count_reloads), expected 1)"
pass "subsequent refreshes inside backoff window do NOT reload (teardown loop fixed)"

# ============================================================
echo "-- 4.1: elapsed backoff makes the dead tag retry-eligible again"
# Back-date the sentinel mtime past update_interval so the window has elapsed.
# Cron path (no force) so this genuinely exercises cold_retry_eligible's elapsed
# branch rather than the force override.
touch -d '2000-01-01 00:00:00' "$SINGBOX_TMPDIR/.rs_cold_deadrs.attempt" 2>/dev/null \
	|| touch -t 200001010000 "$SINGBOX_TMPDIR/.rs_cold_deadrs.attempt"
: >"$RELOAD_LOG"
BBOLT_KNOWN="" run_uc refresh rulesets >/dev/null 2>&1 || true
[ "$(count_reloads)" -eq 1 ] || fail "elapsed-backoff cold tag should reload once (got $(count_reloads))"
pass "after update_interval elapses, cold tag is retry-eligible again"

# ============================================================
echo "-- 4.1: warm tag NEVER reloads and clears any stale sentinel"
: >"$RELOAD_LOG"
rm -f "$SINGBOX_TMPDIR/rs_deadrs.json"
# Pre-plant a sentinel; a tag that is now warm must clear it and never reload.
echo 123 >"$SINGBOX_TMPDIR/.rs_cold_deadrs.attempt"
BBOLT_KNOWN="deadrs" run_uc refresh rulesets force >/dev/null 2>&1 || true
[ "$(count_reloads)" -eq 0 ] || fail "warm tag MUST NOT trigger reload (got $(count_reloads))"
[ -s "$SINGBOX_TMPDIR/rs_deadrs.json" ] || fail "warm refresh did not build rs_deadrs.json"
[ ! -f "$SINGBOX_TMPDIR/.rs_cold_deadrs.attempt" ] || fail "warm extract did not clear cold sentinel"
pass "warm tag: no reload, set rebuilt, sentinel cleared"

# ============================================================
echo "-- 4.1: a cold tag that recovers becomes immediately eligible again"
# Warm extract above cleared the sentinel; go cold again → first cycle eligible
# even on the cron path (no sentinel → eligible without a force override).
# Drop the rs_*.json the warm extract just wrote so any_rulesets_stale sees the
# rule-set as stale (missing file) and the cron path actually reaches the cold
# logic — otherwise the fresh json would short-circuit the whole branch.
: >"$RELOAD_LOG"
rm -f "$SINGBOX_TMPDIR/rs_deadrs.json"
BBOLT_KNOWN="" run_uc refresh rulesets >/dev/null 2>&1 || true
[ "$(count_reloads)" -eq 1 ] || fail "recovered-then-cold tag should reload once (got $(count_reloads))"
pass "cleared sentinel → cold tag eligible without waiting a full interval"

# ============================================================
echo "-- 4.6: failed cache extract leaves no stray rs_*.raw at the real path"
# bbolt -r exits 1 (unknown tag) → cache_extract_srs must clean up its temp file
# and leave neither rs_deadrs.raw nor a 0-byte file behind.
rm -f "$SINGBOX_TMPDIR/rs_deadrs.raw" "$SINGBOX_TMPDIR"/rs_deadrs.raw.tmp.*
BBOLT_KNOWN="" SINGBOX_BOOT_FETCH=1 run_uc fetch-rulesets >/dev/null 2>&1 || true
[ ! -f "$SINGBOX_TMPDIR/rs_deadrs.raw" ] || fail "failed extract left a stray rs_deadrs.raw"
# No leftover temp siblings either.
if ls "$SINGBOX_TMPDIR"/rs_deadrs.raw.tmp.* >/dev/null 2>&1; then
	fail "failed extract left a stray temp sibling"
fi
pass "failed extract leaves no stray/0-byte raw file"

# ============================================================
echo "-- 4.5: wait_for_tags terminates even when 'sleep' is unforkable"
# Shadow `sleep` with a non-executable so system(["sleep","1"]) returns non-zero;
# the loop must bail instead of busy-spinning. Bound the wall-clock to prove it
# does not hang for the full deadline busy-forking bbolt-client.
cat >"$TMPDIR/bin/sleep" <<'EOF'
#!/bin/sh
exit 7
EOF
chmod +x "$TMPDIR/bin/sleep"
: >"$RELOAD_LOG"
# Fresh dead tag, no sentinel → eligible → one reload then poll. With a broken
# sleep the poll must return quickly (we cap at 8s as a hang sentinel).
rm -f "$SINGBOX_TMPDIR/.rs_cold_deadrs.attempt"
start=$(date +%s)
BBOLT_KNOWN="" SINGBOX_RS_CACHE_WAIT=5 run_uc refresh rulesets >/dev/null 2>&1 || true
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -le 8 ] || fail "wait_for_tags busy-spun/hung with broken sleep (${elapsed}s)"
pass "wait_for_tags bails on broken sleep (${elapsed}s)"

# ============================================================
echo "-- 4.1 BUG1: a FUTURE-dated sentinel does NOT wedge the tag (clock skew)"
# An RTC-less router can stamp the sentinel, then have NTP rewind the clock — the
# sentinel mtime ends up in the future. time()-mtime goes negative, which a naive
# >=interval test reads as "still backing off" and wedges the tag forever. The
# guard must treat a future mtime as elapsed → eligible → exactly one reload.
# Cron path (no force) on purpose: force would bypass the backoff outright and
# mask whether the future-mtime guard actually works.
rm -f "$TMPDIR/bin/sleep"   # undo the broken-sleep shim from the 4.5 block above
: >"$RELOAD_LOG"
# rs_*.json must be absent so any_rulesets_stale lets the cron path reach the cold
# logic (the 4.5 block left no json; be explicit so reordering can't mask this).
rm -f "$SINGBOX_TMPDIR/rs_deadrs.json"
# Stamp the sentinel into the future. busybox touch has no -d '+1 hour' and
# busybox date has no -d, so use a fixed far-future -t stamp (CCYYMMDDhhmm,
# kept < 2038 to stay 32-bit-safe) to force mtime > now on every platform.
touch -t 203501010000 "$SINGBOX_TMPDIR/.rs_cold_deadrs.attempt"
BBOLT_KNOWN="" run_uc refresh rulesets >/dev/null 2>&1 || true
[ "$(count_reloads)" -eq 1 ] || fail "future-dated sentinel wedged the tag (got $(count_reloads), expected 1)"
pass "future-dated sentinel is treated as eligible, not wedged"

# ============================================================
echo "-- 4.1 BUG2: force-refresh overrides the backoff; cron (no force) does not"
# Fresh sentinel inside the (1-day) backoff window. A cron-style refresh (no
# force) must STAY throttled — no reload. An explicit UI force-refresh must
# override the window and reload now (operator fixed a dead URL).
: >"$RELOAD_LOG"
# Stamp a fresh sentinel (mtime = now) so the window is wide open.
echo "$(date +%s)" >"$SINGBOX_TMPDIR/.rs_cold_deadrs.attempt"
touch "$SINGBOX_TMPDIR/.rs_cold_deadrs.attempt"
# (a) cron path: refresh WITHOUT the "force" arg → still backing off → no reload.
BBOLT_KNOWN="" run_uc refresh rulesets >/dev/null 2>&1 || true
[ "$(count_reloads)" -eq 0 ] || fail "non-force refresh inside backoff reloaded (got $(count_reloads), expected 0)"
pass "cron refresh (no force) stays throttled inside the backoff window"

# (b) force path: same fresh sentinel, but force=true → backoff overridden → one
#     reload, and the sentinel is re-stamped (tag still cold after the poll).
BBOLT_KNOWN="" run_uc refresh rulesets force >/dev/null 2>&1 || true
[ "$(count_reloads)" -eq 1 ] || fail "force-refresh did not override backoff (got $(count_reloads), expected 1)"
pass "force-refresh overrides the backoff window and reloads"

echo "OK"
