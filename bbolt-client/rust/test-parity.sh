#!/bin/sh
# Parity harness: the Rust binary must match the Go oracle byte-for-byte.
# Pure POSIX sh (no bashisms: no process substitution / pipe-while / local) so it
# runs under dash on the host. Run from bbolt-client/rust/ after building+copying
# ./bbolt-client-rs. Needs ../bbolt-client (the Go tool).
#
# Covers two fixtures:
#   ../cache.db            the real, thin sing-box cache (1 bucket, has rule_set / -r)
#   testdata/stress.db     forces branch pages, overflow pages, inline + nested
#                          buckets, empty bucket, high-byte keys
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
GO="$HERE/../bbolt-client"
RS="$HERE/bbolt-client-rs"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
fail() { echo "PARITY FAIL: $1" >&2; exit 1; }

[ -x "$GO" ] || fail "Go oracle not built at $GO (cd .. && CGO_ENABLED=0 go build -o bbolt-client .)"
[ -x "$RS" ] || fail "Rust binary not at $RS (build + copy it first)"

# run_checks <db> <label>: bucket list, every key list, every value, -r (if rule_set),
# and missing-bucket/key exit codes + texts — all diffed against the Go oracle.
run_checks() {
  DB="$1"; label="$2"
  [ -f "$DB" ] || { echo "skip: $label fixture missing ($DB)"; return; }
  echo "== $label: $DB =="

  "$GO" "$DB" > "$TMP/go.b"; "$RS" "$DB" > "$TMP/rs.b"
  diff "$TMP/go.b" "$TMP/rs.b" >/dev/null || fail "[$label] bucket list differs"
  echo "  ok: bucket list ($(wc -l < "$TMP/go.b" | tr -d ' ') buckets)"

  nkeys=0
  while IFS= read -r B; do
    "$GO" "$DB" "$B" > "$TMP/go.k"; "$RS" "$DB" "$B" > "$TMP/rs.k"
    diff "$TMP/go.k" "$TMP/rs.k" >/dev/null || fail "[$label] key list differs for bucket [$B]"
    while IFS= read -r K; do
      "$GO" "$DB" "$B" "$K" > "$TMP/go.v" 2>/dev/null
      "$RS" "$DB" "$B" "$K" > "$TMP/rs.v" 2>/dev/null
      cmp -s "$TMP/go.v" "$TMP/rs.v" || fail "[$label] value differs for [$B]/[$K]"
      nkeys=$((nkeys + 1))
    done < "$TMP/go.k"
  done < "$TMP/go.b"
  echo "  ok: key lists + values ($nkeys keys)"

  if grep -qx 'rule_set' "$TMP/go.b"; then
    "$GO" "$DB" rule_set > "$TMP/rsk"
    while IFS= read -r K; do
      "$GO" -r "$DB" rule_set "$K" > "$TMP/go.r" 2>/dev/null; grc=$?
      "$RS" -r "$DB" rule_set "$K" > "$TMP/rs.r" 2>/dev/null; rrc=$?
      [ "$grc" = "$rrc" ] || fail "[$label] -r exit differs for [$K] (go=$grc rs=$rrc)"
      cmp -s "$TMP/go.r" "$TMP/rs.r" || fail "[$label] -r output differs for [$K]"
    done < "$TMP/rsk"
    echo "  ok: -r unwrap"
  fi

  B1=$(head -1 "$TMP/go.b")
  "$GO" "$DB" __no_such_bucket__ >/dev/null 2>&1; gb=$?
  "$RS" "$DB" __no_such_bucket__ >/dev/null 2>&1; rb=$?
  [ "$gb" = "$rb" ] || fail "[$label] exit differs: missing bucket (go=$gb rs=$rb)"
  if [ -n "$B1" ]; then
    "$GO" "$DB" "$B1" __no_such_key__ >/dev/null 2>&1; gk=$?
    "$RS" "$DB" "$B1" __no_such_key__ >/dev/null 2>&1; rk=$?
    [ "$gk" = "$rk" ] || fail "[$label] exit differs: missing key (go=$gk rs=$rk)"
  fi
  rbtext=$("$RS" "$DB" __no_such_bucket__ 2>&1)
  [ "$rbtext" = 'no bucket "__no_such_bucket__"' ] || fail "[$label] no-bucket text [$rbtext]"
  echo "  ok: error/exit-code parity"
}

run_checks "$HERE/../cache.db" "real"
run_checks "$HERE/testdata/stress.db" "stress"

# --- db-independent error paths ---
"$GO" /no/such/file.db >/dev/null 2>&1; gf=$?
"$RS" /no/such/file.db >/dev/null 2>&1; rf=$?
[ "$gf" = "$rf" ] || fail "exit differs: missing file (go=$gf rs=$rf)"
"$GO" >/dev/null 2>&1; gu=$?
"$RS" >/dev/null 2>&1; ru=$?
[ "$gu" = "$ru" ] || fail "exit differs: usage (go=$gu rs=$ru)"
rutext=$("$RS" 2>&1)
[ "$rutext" = 'usage: bbolt-client [-r] <db> [bucket] [key]' ] || fail "usage text [$rutext]"
echo "ok: file/usage exit codes + usage text"

# --- locked db => timeout, exit 1 (both tools) ---
if command -v flock >/dev/null 2>&1 && [ -f "$HERE/../cache.db" ]; then
  cp "$HERE/../cache.db" "$TMP/locked.db"
  flock -x "$TMP/locked.db" -c 'sleep 3' &
  LP=$!
  sleep 0.3
  "$GO" "$TMP/locked.db" >/dev/null 2>&1; gl=$?
  rlout=$("$RS" "$TMP/locked.db" 2>&1); rl=$?
  wait "$LP" 2>/dev/null
  { [ "$gl" = "1" ] && [ "$rl" = "1" ]; } || fail "locked-db exit (go=$gl rs=$rl)"
  [ "$rlout" = "timeout" ] || fail "locked-db text [$rlout]"
  echo "ok: locked-db timeout"
else
  echo "skip: flock(1) or cache.db unavailable for lock test"
fi

echo "ALL PARITY CHECKS PASSED"
