#!/bin/sh
# Self-contained regression test for the bbolt reader (lib/bbolt.uc) — no external
# oracle. The reader's output is reduced to a sha256 and compared against committed
# golden hashes under testdata/golden/ (originally captured from the Go reference
# implementation and frozen). Pure POSIX sh (runs under dash).
#
# The reader is driven through ./bbolt-cli.uc, a test-only CLI driver: production
# (nft-rulesets.uc) requires the module in-process and forks nothing.
#
#   ./test.sh                  test lib/bbolt.uc via ./bbolt-cli.uc
#   RUN=<tool> ./test.sh       test some other argv-compatible reader
#   RUN=<tool> ./test.sh gen   (re)generate golden from <tool>
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
LIB="${LIB:-$HERE/../singbox-ui/root/usr/share/singbox-ui/lib}"
RUN="${RUN:-ucode -L $LIB $HERE/bbolt-cli.uc}"
DATA="$HERE/testdata"
GOLDEN="$DATA/golden"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT INT TERM
fail() { echo "FAIL: $1" >&2; exit 1; }

# Byte-level helpers run through ucode, not od/hexdump: the OpenWrt guest ships a
# BusyBox without od, and ucode is a hard dependency of the reader under test anyway.
command -v ucode >/dev/null 2>&1 || fail "ucode not found (required for byte helpers)"
# hexenc <string>: lowercase hex of the argument's bytes
hexenc() { ucode -e 'let s = ARGV[0], o = ""; for (let i = 0; i < length(s); i++) o += sprintf("%02x", ord(s, i)); print(o);' "$1"; }
# rdle <file> <off> <nbytes>: little-endian unsigned integer at OFF (decimal)
rdle() {
  ucode -e '
    let fs = require("fs");
    let f = fs.open(ARGV[0], "r"); if (!f) exit(1);
    f.seek(int(ARGV[1]));
    let b = f.read(int(ARGV[2])), v = 0;
    for (let i = length(b) - 1; i >= 0; i--) v = v * 256 + ord(b, i);
    f.close(); printf("%u\n", v);
  ' "$1" "$2" "$3"
}

# dump <db>: deterministic, binary-safe stream of the whole tree
#   B <bucket>            (one per bucket, in listing order)
#   K <keyhex> V <sha256> (one per key: key hex-encoded, value hashed)
dump() {
  db="$1"
  $RUN "$db" | while IFS= read -r B; do
    printf 'B %s\n' "$B"
    $RUN "$db" "$B" | while IFS= read -r K; do
      kx=$(hexenc "$K")
      vs=$($RUN "$db" "$B" "$K" 2>/dev/null | sha256sum | cut -c1-64)
      printf 'K %s V %s\n' "$kx" "$vs"
    done
  done
}
# dump_srs <db>: R <keyhex> S <sha256-of-.srs> for each rule_set key (-r path)
dump_srs() {
  db="$1"
  $RUN "$db" rule_set | while IFS= read -r K; do
    kx=$(hexenc "$K")
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
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 5"   # not in stock OpenWrt
adv() {
  desc="$1"; db="$2"; arg="$3"; want="$4"
  # shellcheck disable=SC2086  # $TO / $arg are intentionally word-split
  rc=0; out=$($TO $RUN "$db" $arg 2>&1) || rc=$?
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
# and subslices, never an OOB-panic/abort. Patch the frozen cache.db with rdle/dd.
# page header: count u16 @+10; element header (leaf) lflags@+0,
# pos@+4, ksize@+8, vsize@+12 — a forged pos/ksize/count drives a read or slice
# past the page. Pre-fix these aborted (exit 134); post-fix they exit 1.
psf=$(rdle "$DATA/cache.db" 24 4)
szf=$(wc -c < "$DATA/cache.db")
m0t=$(rdle "$DATA/cache.db" 64 8)
m1t=$(rdle "$DATA/cache.db" $((psf+64)) 8)
if [ "$m0t" -ge "$m1t" ]; then rootf=$(rdle "$DATA/cache.db" 32 8)
else rootf=$(rdle "$DATA/cache.db" $((psf+32)) 8); fi
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

# 2c. CRITIC/missed-5: a forged meta with a VALID checksum but a tiny pageSize +
# a huge root pgid drives page()'s offset math `id * ps (+16)` into the top of
# the u64 range. The page-offset computation must reject this via checked
# arithmetic (and the bounds-checked readers downstream) with a clean
# "invalid database" exit, never an OOB-panic/abort. Unlike the forged-element
# cases above (which keep the real pageSize), this forges the meta itself, so we
# must recompute meta0's FNV-1a64 checksum — done with ucode (true int64).
# write a little-endian integer (decimal, possibly > 2^63) of N bytes at OFF.
_wle() { # $1=file $2=off $3=decimal-value $4=nbytes
  ucode -e '
    let h = +ARGV[2];
    let fs = require("fs");
    let f = fs.open(ARGV[0], "r+"); if (!f) exit(1);
    f.seek(int(ARGV[1])); let n = int(ARGV[3]); let o = "";
    for (let i = 0; i < n; i++) { o += chr(h & 0xff); h = h >> 8; }
    f.write(o); f.close();
  ' "$1" "$2" "$3" "$4"
}
cp "$DATA/cache.db" "$TMP/fm.db"
# pageSize=3 @ meta0+8 (file off 24); root pgid chosen so root*3 == 2^64-1, the
# exact value whose `+16` wraps past the u64 range on the pre-checked code.
_wle "$TMP/fm.db" 24 3 4
_wle "$TMP/fm.db" 32 6148914691236517205 8
# recompute FNV-1a64 over meta0's 56 covered bytes (file off 16..72) and store @72.
_ck=$(ucode -e '
  let fs = require("fs");
  let f = fs.open(ARGV[0], "r"); if (!f) exit(1);
  f.seek(16); let b = f.read(56); f.close();
  let h = 0xcbf29ce484222325;
  for (let i = 0; i < length(b); i++) { h ^= ord(b, i); h *= 0x100000001b3; }
  printf("%u\n", h);
' "$TMP/fm.db")
_wle "$TMP/fm.db" 72 "$_ck" 8
adv "forged meta tiny-pageSize + huge root pgid" "$TMP/fm.db" "" 1

# 3. error texts + exit codes (known-good; no oracle)
B1=$($RUN "$DATA/cache.db" | head -1)
[ "$($RUN "$DATA/cache.db" __nb__ 2>&1)" = 'no bucket "__nb__"' ] || fail "no-bucket text"
[ "$($RUN "$DATA/cache.db" "$B1" __nk__ 2>&1)" = 'no key "__nk__"' ] || fail "no-key text"
[ "$($RUN 2>&1)" = 'usage: bbolt-client [-r] <db> [bucket] [key]' ] || fail "usage text"
rc=0; $RUN /no/such/file.db >/dev/null 2>&1 || rc=$?; [ "$rc" = "1" ] || fail "missing-file exit $rc (want 1)"
rc=0; $RUN >/dev/null 2>&1 || rc=$?; [ "$rc" = "2" ] || fail "usage exit $rc (want 2)"
echo "ok: error texts + exit codes"

# 4. an advisory exclusive flock does NOT block the reader. The ucode port takes
# no flock: bbolt is copy-on-write with two checksummed meta pages (select_root
# picks the higher-txid valid one), so a concurrent writer can't hand us a torn
# tree; a half-grown file trips a bounds guard -> clean error -> cron retries.
# (Was: the Rust client took LOCK_SH|NB and timed out -> exit 1 "timeout".)
if command -v flock >/dev/null 2>&1; then
  cp "$DATA/cache.db" "$TMP/locked.db"
  flock -x "$TMP/locked.db" -c 'sleep 3' & LP=$!; sleep 0.3
  # shellcheck disable=SC2086  # $TO is intentionally word-split
  out=$($TO $RUN "$TMP/locked.db" 2>&1); rc=$?
  wait "$LP" 2>/dev/null
  { [ "$rc" = "0" ] && [ -n "$out" ]; } || fail "locked-db read-through (exit $rc out [$out])"
  echo "ok: locked-db read-through (no flock by design)"
else
  echo "skip: flock(1) unavailable"
fi

echo "ALL CHECKS PASSED ($RUN)"
