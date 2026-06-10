#!/bin/sh
# tests/test_docker_scripts.sh — lint the QEMU image scripts for two
# ordering/robustness invariants that are easy to silently regress:
#   S5-6: entrypoint.sh must wait for SSH before tar|ssh injection.
#   S5-7: build-snapshot.sh must poll `info snapshots` (no blind sleep
#         deciding success) around savevm.
set -e
cd "$(dirname "$0")/.."

ENTRY=tests/docker/entrypoint.sh
SNAP=tests/docker/build-snapshot.sh
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

echo "-- S5-7: build-snapshot polls 'info snapshots' (no blind sleep gating savevm)"
[ -f "$SNAP" ] || fail "$SNAP missing"
grep -q 'savevm boot-state' "$SNAP" || fail "savevm boot-state not found"
# Must contain an active poll of the snapshot list (loop body greps for
# boot-state in `info snapshots` output), not just blind sleeps.
grep -q 'info snapshots' "$SNAP" || fail "no 'info snapshots' poll in build-snapshot.sh"
grep -Eq 'while|for|until' "$SNAP" || fail "no poll loop in build-snapshot.sh"
# A loop body that probes `info snapshots` for boot-state must exist (the
# readiness poll), distinct from the serial-sock settle loop. This is the
# teeth: the old blind-sleep form had `info snapshots` only as a one-shot
# diagnostic between fixed sleeps, never as a readiness gate.
grep -Eq 'info snapshots.*boot-state|boot-state.*info snapshots' "$SNAP" \
	|| grep -Eq 'snap_ready|while .*savevm|savevm_done' "$SNAP" \
	|| fail "no savevm readiness poll (blind sleep still gates savevm)"
echo "  PASS: build-snapshot polls info snapshots around savevm"

echo "OK"
