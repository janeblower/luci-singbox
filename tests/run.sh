#!/bin/sh
# tests/run.sh
set -e
cd "$(dirname "$0")/.."

echo "==> Lua tests"
for t in tests/test_*.lua; do
  [ -e "$t" ] || continue
  echo "-- $t"
  lua5.1 "$t"
done

echo "==> Shell tests"
for t in tests/test_*.sh; do
  [ -e "$t" ] || continue
  echo "-- $t"
  sh "$t"
done

echo "All tests passed."
