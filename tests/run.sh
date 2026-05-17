#!/bin/sh
# tests/run.sh
set -e
cd "$(dirname "$0")/.."

# If UCODE_BIN/UCODE_LIB_DIR are set by the caller (e.g. CI), pass them
# through to each shell test. UCODE_STUB_DIR defaults to the in-tree stubs.
: "${UCODE_STUB_DIR:=$PWD/tests/ucode-stubs}"
export UCODE_STUB_DIR
[ -n "${UCODE_BIN:-}" ] && export UCODE_BIN
[ -n "${UCODE_LIB_DIR:-}" ] && export UCODE_LIB_DIR

echo "==> Shell tests"
for t in tests/test_*.sh; do
  [ -e "$t" ] || continue
  echo "-- $t"
  sh "$t"
done

echo "All tests passed."
