#!/bin/sh
# Self-contained regression test for bbolt-client-rs — no external oracle.
# The binary's output is reduced to a sha256 and compared against committed golden
# hashes under testdata/golden/ (originally captured from the Go reference
# implementation and frozen). Pure POSIX sh (runs under dash).
#
#   ./test.sh                                  test the native ./bbolt-client-rs
#   RUN="qemu-aarch64 target/aarch64-.../bbolt-client-rs" ./test.sh   test a cross binary
#   RUN=<tool> ./test.sh gen                   (re)generate golden from <tool>
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
RUN="${RUN:-$HERE/bbolt-client-rs}"
DATA="$HERE/testdata"
GOLDEN="$DATA/golden"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT INT TERM
fail() { echo "FAIL: $1" >&2; exit 1; }

# dump <db>: deterministic, binary-safe stream of the whole tree
#   B <bucket>            (one per bucket, in listing order)
#   K <keyhex> V <sha256> (one per key: key hex-encoded, value hashed)
dump() {
  db="$1"
  $RUN "$db" | while IFS= read -r B; do
    printf 'B %s\n' "$B"
    $RUN "$db" "$B" | while IFS= read -r K; do
      kx=$(printf '%s' "$K" | od -An -v -tx1 | tr -d ' \n')
      vs=$($RUN "$db" "$B" "$K" 2>/dev/null | sha256sum | cut -c1-64)
      printf 'K %s V %s\n' "$kx" "$vs"
    done
  done
}
# dump_srs <db>: R <keyhex> S <sha256-of-.srs> for each rule_set key (-r path)
dump_srs() {
  db="$1"
  $RUN "$db" rule_set | while IFS= read -r K; do
    kx=$(printf '%s' "$K" | od -An -v -tx1 | tr -d ' \n')
    ss=$($RUN -r "$db" rule_set "$K" 2>/dev/null | sha256sum | cut -c1-64)
    printf 'R %s S %s\n' "$kx" "$ss"
  done
}
h() { sha256sum | cut -c1-64; }

if [ "${1:-check}" = "gen" ]; then
  mkdir -p "$GOLDEN"
  dump     "$DATA/cache.db"  | h > "$GOLDEN/cache.sha"
  dump     "$DATA/stress.db" | h > "$GOLDEN/stress.sha"
  dump_srs "$DATA/cache.db"  | h > "$GOLDEN/cache.srs.sha"
  $RUN "$DATA/overflow.db" x      > "$GOLDEN/overflow.x"
  echo "golden written to $GOLDEN (from: $RUN)"
  exit 0
fi

command -v "${RUN%% *}" >/dev/null 2>&1 || fail "tool not found: ${RUN%% *}"

# 1. whole-tree parity vs golden (buckets, keys, values, ordering)
[ "$(dump     "$DATA/cache.db"  | h)" = "$(cat "$GOLDEN/cache.sha")" ]     || fail "cache.db tree differs from golden"
echo "ok: cache.db tree"
[ "$(dump     "$DATA/stress.db" | h)" = "$(cat "$GOLDEN/stress.sha")" ]    || fail "stress.db tree differs from golden"
echo "ok: stress.db tree (branch/overflow/inline/nested/high-byte)"
[ "$(dump_srs "$DATA/cache.db"  | h)" = "$(cat "$GOLDEN/cache.srs.sha")" ] || fail "-r output differs from golden"
echo "ok: -r unwrap"

# 2. adversarial: clean exit, never crash (132/134/139); bogus-overflow matches golden
adv() {
  desc="$1"; db="$2"; arg="$3"; want="$4"
  rc=0; out=$(timeout 5 $RUN "$db" $arg 2>&1) || rc=$?
  case "$rc" in 132|134|139) fail "[$desc] CRASHED (exit $rc): $out" ;; esac
  [ "$rc" = "$want" ] || fail "[$desc] exit $rc, want $want ($out)"
  echo "ok: $desc (clean exit $rc)"
}
adv "cyclic recursion guard"   "$DATA/cyclic.db" x 1
adv "pgid-wrap self-id guard"  "$DATA/wrap.db"   x 1
$RUN "$DATA/overflow.db" x > "$TMP/o" 2>/dev/null
cmp -s "$GOLDEN/overflow.x" "$TMP/o" || fail "bogus-overflow output differs from golden"
echo "ok: bogus-overflow parity"
printf 'garbage!' > "$TMP/g8"; adv "8-byte garbage" "$TMP/g8" "" 1
head -c 100 "$DATA/cache.db" > "$TMP/tr"; adv "truncated cache.db" "$TMP/tr" "" 1

# 2b. S5.7: forged element fields must clean-exit via the bounds-checked readers
# and subslices, never an OOB-panic/abort. Patch the frozen cache.db with od/dd
# (no extra deps). page header: count u16 @+10; element header (leaf) lflags@+0,
# pos@+4, ksize@+8, vsize@+12 — a forged pos/ksize/count drives a read or slice
# past the page. Pre-fix these aborted (exit 134); post-fix they exit 1.
psf=$(od -An -tu4 -j24 -N4 "$DATA/cache.db" | tr -d ' ')
szf=$(wc -c < "$DATA/cache.db")
m0t=$(od -An -tu8 -j64        -N8 "$DATA/cache.db" | tr -d ' ')
m1t=$(od -An -tu8 -j$((psf+64)) -N8 "$DATA/cache.db" | tr -d ' ')
if [ "$m0t" -ge "$m1t" ]; then rootf=$(od -An -tu8 -j32 -N8 "$DATA/cache.db" | tr -d ' ')
else rootf=$(od -An -tu8 -j$((psf+32)) -N8 "$DATA/cache.db" | tr -d ' '); fi
reo=$(( rootf * psf + 16 ))   # first element header of the active root page
# (a) every page's entry count -> 0xFFFF (meta pages ignore count, so the tree
# still parses far enough to walk the root and overrun its element loop).
cp "$DATA/cache.db" "$TMP/fc.db"
o=10; while [ "$o" -lt "$szf" ]; do printf '\377\377' | dd of="$TMP/fc.db" bs=1 seek="$o" conv=notrunc 2>/dev/null; o=$(( o + psf )); done
adv "forged page entry-count" "$TMP/fc.db" "" 1
# (b) forged ksize of the root's first element -> key subslice runs OOB.
cp "$DATA/cache.db" "$TMP/fk.db"; printf '\377\377\377\377' | dd of="$TMP/fk.db" bs=1 seek=$(( reo + 8 )) conv=notrunc 2>/dev/null
adv "forged element ksize" "$TMP/fk.db" "" 1
# (c) forged pos of the root's first element -> subslice base runs OOB.
cp "$DATA/cache.db" "$TMP/fp.db"; printf '\377\377\377\377' | dd of="$TMP/fp.db" bs=1 seek=$(( reo + 4 )) conv=notrunc 2>/dev/null
adv "forged element pos" "$TMP/fp.db" "" 1

# 3. error texts + exit codes (known-good; no oracle)
B1=$($RUN "$DATA/cache.db" | head -1)
[ "$($RUN "$DATA/cache.db" __nb__ 2>&1)" = 'no bucket "__nb__"' ] || fail "no-bucket text"
[ "$($RUN "$DATA/cache.db" "$B1" __nk__ 2>&1)" = 'no key "__nk__"' ] || fail "no-key text"
[ "$($RUN 2>&1)" = 'usage: bbolt-client [-r] <db> [bucket] [key]' ] || fail "usage text"
rc=0; $RUN /no/such/file.db >/dev/null 2>&1 || rc=$?; [ "$rc" = "1" ] || fail "missing-file exit $rc (want 1)"
rc=0; $RUN >/dev/null 2>&1 || rc=$?; [ "$rc" = "2" ] || fail "usage exit $rc (want 2)"
echo "ok: error texts + exit codes"

# 4. locked db => timeout, exit 1
if command -v flock >/dev/null 2>&1; then
  cp "$DATA/cache.db" "$TMP/locked.db"
  flock -x "$TMP/locked.db" -c 'sleep 3' & LP=$!; sleep 0.3
  out=$(timeout 5 $RUN "$TMP/locked.db" 2>&1); rc=$?
  wait "$LP" 2>/dev/null
  { [ "$rc" = "1" ] && [ "$out" = "timeout" ]; } || fail "locked-db (exit $rc out [$out])"
  echo "ok: locked-db timeout"
else
  echo "skip: flock(1) unavailable"
fi

echo "ALL CHECKS PASSED ($RUN)"
