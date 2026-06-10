#!/bin/sh
# Parity harness: the Rust binary must match the Go oracle byte-for-byte on cache.db.
# Pure POSIX sh (no bashisms: no process substitution / pipe-while / local) so it
# runs under dash on the host. Run from bbolt-client/rust/ after building+copying
# ./bbolt-client-rs. Needs ../bbolt-client (the Go tool) and ../cache.db.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
GO="$HERE/../bbolt-client"
RS="$HERE/bbolt-client-rs"
DB="$HERE/../cache.db"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
fail() { echo "PARITY FAIL: $1" >&2; exit 1; }

[ -x "$GO" ] || fail "Go oracle not built at $GO (run: (cd .. && CGO_ENABLED=0 go build -o bbolt-client .))"
[ -x "$RS" ] || fail "Rust binary not at $RS (build + copy it first)"
[ -f "$DB" ] || fail "fixture db missing at $DB"

# --- buckets ---
"$GO" "$DB" > "$TMP/go.b"; "$RS" "$DB" > "$TMP/rs.b"
diff "$TMP/go.b" "$TMP/rs.b" >/dev/null || fail "bucket list differs"
echo "ok: bucket list ($(wc -l < "$TMP/go.b" | tr -d ' ') buckets)"

# --- key lists + values (every key in every bucket) ---
nkeys=0
while IFS= read -r B; do
  "$GO" "$DB" "$B" > "$TMP/go.k"; "$RS" "$DB" "$B" > "$TMP/rs.k"
  diff "$TMP/go.k" "$TMP/rs.k" >/dev/null || fail "key list differs for bucket [$B]"
  while IFS= read -r K; do
    "$GO" "$DB" "$B" "$K" > "$TMP/go.v"; "$RS" "$DB" "$B" "$K" > "$TMP/rs.v"
    cmp -s "$TMP/go.v" "$TMP/rs.v" || fail "value differs for [$B]/[$K]"
    nkeys=$((nkeys + 1))
  done < "$TMP/go.k"
done < "$TMP/go.b"
echo "ok: key lists + values ($nkeys keys)"

# --- -r envelope unwrap (only if a rule_set bucket exists) ---
if grep -qx 'rule_set' "$TMP/go.b"; then
  "$GO" "$DB" rule_set > "$TMP/rsk"
  while IFS= read -r K; do
    "$GO" -r "$DB" rule_set "$K" > "$TMP/go.r" 2>/dev/null; grc=$?
    "$RS" -r "$DB" rule_set "$K" > "$TMP/rs.r" 2>/dev/null; rrc=$?
    [ "$grc" = "$rrc" ] || fail "-r exit differs for [$K] (go=$grc rs=$rrc)"
    cmp -s "$TMP/go.r" "$TMP/rs.r" || fail "-r output differs for [$K]"
  done < "$TMP/rsk"
  echo "ok: -r unwrap"
else
  echo "skip: no rule_set bucket in fixture"
fi

# --- error paths: exit codes must match; parity-critical texts must match ---
B1=$(head -1 "$TMP/go.b")
"$GO" "$DB" __no_such_bucket__ >/dev/null 2>&1; gb=$?
"$RS" "$DB" __no_such_bucket__ >/dev/null 2>&1; rb=$?
[ "$gb" = "$rb" ] || fail "exit differs: missing bucket (go=$gb rs=$rb)"
"$GO" "$DB" "$B1" __no_such_key__ >/dev/null 2>&1; gk=$?
"$RS" "$DB" "$B1" __no_such_key__ >/dev/null 2>&1; rk=$?
[ "$gk" = "$rk" ] || fail "exit differs: missing key (go=$gk rs=$rk)"
"$GO" /no/such/file.db >/dev/null 2>&1; gf=$?
"$RS" /no/such/file.db >/dev/null 2>&1; rf=$?
[ "$gf" = "$rf" ] || fail "exit differs: missing file (go=$gf rs=$rf)"
"$GO" >/dev/null 2>&1; gu=$?
"$RS" >/dev/null 2>&1; ru=$?
[ "$gu" = "$ru" ] || fail "exit differs: usage (go=$gu rs=$ru)"
rbtext=$("$RS" "$DB" __no_such_bucket__ 2>&1)
[ "$rbtext" = 'no bucket "__no_such_bucket__"' ] || fail "no-bucket text [$rbtext]"
rktext=$("$RS" "$DB" "$B1" __no_such_key__ 2>&1)
[ "$rktext" = 'no key "__no_such_key__"' ] || fail "no-key text [$rktext]"
echo "ok: error/exit-code parity"

# --- locked db => timeout, exit 1 (both tools) ---
if command -v flock >/dev/null 2>&1; then
  cp "$DB" "$TMP/locked.db"
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
  echo "skip: flock(1) unavailable for lock test"
fi

echo "ALL PARITY CHECKS PASSED"
