#!/bin/sh
# tests/backend/test_vm_no_node_tests.sh
# Node/JS tests must NOT enter the VM run path: the entrypoint restricts
# SB_DOMAIN so tests/ui/* (node domain) is excluded from the guest run. Also
# asserts the ucode hard-fail guard (guard A) text is untouched.
set -eu
cd "$(dirname "$0")/../.."
fail() { echo "FAIL: $1" >&2; exit 1; }

EP=tests/docker/entrypoint.sh

# The guest suite invocation must pass an SB_DOMAIN that excludes 'ui'.
grep -qE "SB_DOMAIN=[\"']?[^\"']*backend" "$EP" \
	|| fail "entrypoint does not set SB_DOMAIN for the guest run"
grep -qE "SB_DOMAIN=[\"'][^\"']*\bui\b" "$EP" \
	&& fail "entrypoint SB_DOMAIN still includes the ui domain (node tests would run in VM)"

# Dry-run the resolved VM list with the same SB_DOMAIN the entrypoint uses and
# assert NO tests/ui/ files (those are the node-gated ones) are selected.
out=$(SB_DRY_RUN=1 SINGBOX_TESTS_IN_VM=1 SB_DOMAIN="backend packaging bbolt" \
	SB_SUITE="backend ui cross" sh tests/run.sh 2>/dev/null)
printf '%s\n' "$out" | grep -q 'tests/ui/' \
	&& fail "tests/ui/ files still selected under the VM SB_DOMAIN"
printf '%s\n' "$out" | grep -q 'tests/backend/' \
	|| fail "backend tests missing from the VM list"

# The ucode hard-fail guard (guard A) must remain present and unmodified in run.sh.
grep -q 'SKIPped for a MISSING ucode interpreter' tests/run.sh \
	|| fail "ucode hard-fail guard text changed/removed"

echo "OK"
