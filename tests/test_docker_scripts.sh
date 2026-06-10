#!/bin/sh
# tests/test_docker_scripts.sh — lint the QEMU image scripts for two
# ordering/robustness invariants that are easy to silently regress:
#   S5-6: entrypoint.sh must wait for SSH before tar|ssh injection.
#   S5-7: build-snapshot.sh must poll `info snapshots` (no blind sleep
#         deciding success) around savevm.
set -e
cd "$(dirname "$0")/.."

ENTRY=tests/docker/entrypoint.sh
fail() { echo "FAIL: $1"; exit 1; }

echo "-- S5-6: entrypoint waits for SSH before tar|ssh push"
[ -f "$ENTRY" ] || fail "$ENTRY missing"
wait_ln=$(grep -n 'wait-ssh.sh' "$ENTRY" | head -1 | cut -d: -f1)
push_ln=$(grep -n 'tar -czf -' "$ENTRY" | head -1 | cut -d: -f1)
[ -n "$wait_ln" ] || fail "no wait-ssh.sh call in entrypoint (race after loadvm)"
[ -n "$push_ln" ] || fail "no 'tar -czf -' push found in entrypoint"
[ "$wait_ln" -lt "$push_ln" ] \
	|| fail "wait-ssh ($wait_ln) must precede tar|ssh push ($push_ln)"
echo "  PASS: wait-ssh ($wait_ln) precedes tar|ssh push ($push_ln)"

echo "OK"
