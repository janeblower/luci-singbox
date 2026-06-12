#!/bin/bash
# tests/docker/entrypoint.sh — container ENTRYPOINT for the published
# openwrt-test image.
#
# Per-run flow:
# 1. Create a CoW overlay on top of /var/lib/qemu/base.qcow2 so each
#    run starts from clean snapshot state.
# 2. Boot qemu with -loadvm boot-state (~3-5s).
# 3. Re-trigger SLIRP DHCP inside the guest (known loadvm quirk).
# 4. tar-stream the host's /work into the guest's /tmp/work.
# 5. ssh-exec `sh tests/run.sh` with SINGBOX_TESTS_IN_VM=1.
# 6. Propagate exit code; on failure with KEEP_VM=1, sleep instead of
#    exiting so the operator can socat into the consoles.

set -euo pipefail

BASE_QCOW="/var/lib/qemu/base.qcow2"
RUN_QCOW="/tmp/run.qcow2"
SERIAL_SOCK="/tmp/qemu-serial.sock"
MON_SOCK="/tmp/qemu-monitor.sock"
SSH_PORT=2222
SSH_USER=root
SSH_PASS="admin"

test -f "$BASE_QCOW" || { echo "FAIL: $BASE_QCOW missing (image misbuilt)" >&2; exit 1; }
test -w /dev/kvm   || { echo "FAIL: /dev/kvm not writable (pass --device /dev/kvm)" >&2; exit 1; }
WORK_DIR="${WORK_DIR:-/work}"
test -d "$WORK_DIR" || { echo "FAIL: \$WORK_DIR=$WORK_DIR not a directory (pass -v \$PWD:/work or set WORK_DIR)" >&2; exit 1; }

echo "==> stage per-run qcow2"
# We need three things that interact:
#   1. The base.qcow2's internal snapshot 'boot-state' must be visible
#      to -loadvm so we boot from memory + disk state instantly.
#   2. The base.qcow2 must NOT be mutated by the test run — it lives
#      inside the image layer and is reused per run.
#   3. The VM topology (drive + nic + serial) must match what savevm
#      saw, otherwise loadvm bails with "Unknown savevm section ..."
#      or "Unknown ramblock ...".
#
# What does NOT work:
#   - `qemu-img create -f qcow2 -b base.qcow2 run.qcow2` — qcow2
#     internal snapshots live in the metadata of one file. A
#     backing-chain overlay has its OWN empty snapshot list, so
#     `-loadvm boot-state` aborts with "Snapshot 'boot-state' does
#     not exist in one or more devices".
#   - `-drive ...,snapshot=on` — qemu opens base.qcow2 read-only,
#     redirects writes elsewhere, but the loadvm path treats the
#     drive as a fresh disk and refuses to find any snapshot. Same
#     error as the backing-chain case.
#
# What works: copy base.qcow2 to a per-run file. cp preserves the
# snapshot index. The run file gets mutated during the test, then
# we delete it. ~200 MiB on a tmpfs is ~1-2 s — small price.
cp "$BASE_QCOW" "$RUN_QCOW"

echo "==> boot qemu via loadvm"
rm -f "$SERIAL_SOCK" "$MON_SOCK"
qemu-system-x86_64 \
	-enable-kvm \
	-nodefaults \
	-display none \
	-m 512M \
	-smp 2 \
	-drive "file=$RUN_QCOW,if=virtio,format=qcow2" \
	-nic "user,model=virtio,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" \
	-chardev "socket,id=ser0,path=$SERIAL_SOCK,server=on,wait=off" \
	-serial chardev:ser0 \
	-monitor "unix:$MON_SOCK,server,nowait" \
	-loadvm boot-state \
	&

QEMU_PID=$!

cleanup() {
	# Best-effort polite shutdown via monitor; falls back to kill.
	# shellcheck disable=SC2317  # called via trap
	printf 'quit\n' | socat - "UNIX-CONNECT:$MON_SOCK" 2>/dev/null || true
	# shellcheck disable=SC2317
	kill -TERM "$QEMU_PID" 2>/dev/null || true
	# shellcheck disable=SC2317
	wait "$QEMU_PID" 2>/dev/null || true
	# shellcheck disable=SC2317
	rm -f "$SERIAL_SOCK" "$MON_SOCK" "$RUN_QCOW"
}

# KEEP_VM=1 disables auto-cleanup for inspection on failure.
if [ "${KEEP_VM:-0}" = "1" ]; then
	trap 'echo "==> KEEP_VM=1, sleeping (socat into $SERIAL_SOCK)"; sleep infinity' EXIT
else
	trap cleanup EXIT
fi

echo "==> wait for SSH"
# Deadline raised 30s -> 90s (audit 10.6): a loaded GitHub runner can take
# longer than 30s to reach the SSH banner after `-loadvm`, so a slow KVM boot
# was flaking the whole job. 90s is generous headroom over a healthy ~5s boot
# while still failing fast on a genuinely dead VM.
/opt/wait-ssh.sh 127.0.0.1 "$SSH_PORT" 90

# usermode SLIRP can lose its DHCP lease across loadvm — refresh it.
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
SSH="sshpass -p $SSH_PASS ssh $SSH_OPTS -p $SSH_PORT $SSH_USER@127.0.0.1"

# wait-ssh confirms the SSH banner, but immediately after loadvm the SLIRP
# DHCP lease may not have refreshed yet, so the FIRST guest exec (the udhcpc
# refresh itself) can transiently fail to connect/authenticate. Retry it a few
# times with a short backoff (audit 10.6) so a slow post-loadvm DHCP refresh
# does not flake the run. This is a first-connectivity probe: once one exec
# succeeds, the channel is up for the tar-stream and the suite run.
first_exec() {
	tries=1
	while :; do
		# shellcheck disable=SC2086  # SSH_OPTS intentionally splits
		if $SSH 'udhcpc -i eth0 -n -q >/dev/null 2>&1 || true'; then
			return 0
		fi
		if [ "$tries" -ge 5 ]; then
			echo "FAIL: guest unreachable over SSH after 5 attempts (DHCP not up?)" >&2
			return 1
		fi
		echo "WARN: first guest exec failed (attempt $tries/5), retrying in 2s..." >&2
		sleep 2
		tries=$((tries + 1))
	done
}
first_exec

echo "==> inject working tree into guest:/tmp/work"
tar -czf - \
	--exclude=.git \
	--exclude=node_modules \
	--exclude=.build/sdk \
	--exclude=.claire \
	--exclude=.claude \
	--exclude=.swarm \
	--exclude=dist \
	-C "$WORK_DIR" . \
	| $SSH 'mkdir -p /tmp/work && tar -xzf - -C /tmp/work'

echo "==> run suite inside guest"
set +e
$SSH 'cd /tmp/work && SINGBOX_TESTS_IN_VM=1 sh tests/run.sh'
RC=$?
set -e

echo "==> suite exit: $RC"
exit "$RC"
