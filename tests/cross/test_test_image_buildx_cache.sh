#!/bin/sh
# tests/cross/test_test_image_buildx_cache.sh
# Guard: test-image.yml must use a buildx layer cache so re-runs are fast.
set -eu
cd "$(dirname "$0")/../.."
fail() { echo "FAIL: $1" >&2; exit 1; }
TI=.github/workflows/test-image.yml

grep -q 'actions/cache@' "$TI"         || fail "test-image.yml has no actions/cache step"
grep -q '/tmp/.buildx-cache' "$TI"     || fail "test-image.yml does not cache the buildx layer dir"
grep -q 'cache-from: type=local' "$TI" || fail "build-push-action missing cache-from"
grep -q 'cache-to: type=local'   "$TI" || fail "build-push-action missing cache-to"
echo "OK"
