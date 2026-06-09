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
test -d /work      || { echo "FAIL: /work not mounted (-v \$PWD:/work)" >&2; exit 1; }

echo "==> create per-run qcow2 overlay"
qemu-img create -f qcow2 -b "$BASE_QCOW" -F qcow2 "$RUN_QCOW" >/dev/null

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
/opt/wait-ssh.sh 127.0.0.1 "$SSH_PORT" 30

# usermode SLIRP can lose its DHCP lease across loadvm — refresh it.
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
SSH="sshpass -p $SSH_PASS ssh $SSH_OPTS -p $SSH_PORT $SSH_USER@127.0.0.1"

# shellcheck disable=SC2086  # SSH_OPTS intentionally splits
$SSH 'udhcpc -i eth0 -n -q >/dev/null 2>&1 || true'

echo "==> inject working tree into guest:/tmp/work"
tar -czf - \
	--exclude=.git \
	--exclude=node_modules \
	--exclude=.build/sdk \
	--exclude=.claire \
	--exclude=.swarm \
	--exclude=dist \
	-C /work . \
	| $SSH 'mkdir -p /tmp/work && tar -xzf - -C /tmp/work'

echo "==> run suite inside guest"
set +e
$SSH 'cd /tmp/work && SINGBOX_TESTS_IN_VM=1 sh tests/run.sh'
RC=$?
set -e

echo "==> suite exit: $RC"
exit "$RC"
