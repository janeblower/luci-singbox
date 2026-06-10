#!/bin/bash
# tests/docker/build-snapshot.sh — image-build-time helper.
#
# 1. Convert the gzipped raw OpenWrt rootfs to qcow2 and expand to 1G.
# 2. Boot qemu with serial + monitor on unix sockets and SSH hostfwd
#    on 2222.
# 3. Drive the serial console via build-snapshot.expect to seed the
#    guest (passwd, sing-box).
# 4. Wait for SSH on 127.0.0.1:2222 to confirm dropbear is live.
# 5. Issue `savevm boot-state` + `quit` via the qemu monitor.
# 6. Verify the snapshot exists in the qcow2.
#
# Requires /dev/kvm (the Dockerfile RUN that calls this must be run
# with appropriate device access).

set -euo pipefail

IMAGE_FILE="${IMAGE_FILE:?IMAGE_FILE env var required}"
QCOW="/var/lib/qemu/base.qcow2"
SERIAL_SOCK="/tmp/qemu-serial.sock"
MON_SOCK="/tmp/qemu-monitor.sock"

cd /var/lib/qemu-image
test -f "$IMAGE_FILE" || { echo "FAIL: $IMAGE_FILE missing" >&2; exit 1; }

mkdir -p /var/lib/qemu

echo "==> decompress rootfs"
gunzip --stdout "$IMAGE_FILE" > /var/lib/qemu/base.raw

echo "==> convert to qcow2 + resize to 1G"
qemu-img convert -f raw -O qcow2 /var/lib/qemu/base.raw "$QCOW"
qemu-img resize "$QCOW" 1G
rm /var/lib/qemu/base.raw

# Sanity: /dev/kvm present.
test -w /dev/kvm || { echo "FAIL: /dev/kvm not writable" >&2; exit 1; }

echo "==> start qemu in background"
rm -f "$SERIAL_SOCK" "$MON_SOCK"
qemu-system-x86_64 \
	-enable-kvm \
	-nodefaults \
	-display none \
	-m 512M \
	-smp 2 \
	-drive "file=$QCOW,if=virtio,format=qcow2" \
	-nic "user,model=virtio,hostfwd=tcp:127.0.0.1:2222-:22" \
	-chardev "socket,id=ser0,path=$SERIAL_SOCK,server=on,wait=off" \
	-serial chardev:ser0 \
	-monitor "unix:$MON_SOCK,server,nowait" \
	&

QEMU_PID=$!
cleanup_build() { kill -TERM "$QEMU_PID" 2>/dev/null || true; rm -f "$SERIAL_SOCK" "$MON_SOCK"; }
trap cleanup_build EXIT

# Wait for the serial socket to appear (qemu may take a beat to bind).
for _ in $(seq 1 10); do
	test -S "$SERIAL_SOCK" && break
	sleep 1
done
test -S "$SERIAL_SOCK" || { echo "FAIL: serial sock never appeared" >&2; exit 1; }

echo "==> drive first-boot serial dialog"
SERIAL_SOCK="$SERIAL_SOCK" expect /opt/build-snapshot.expect

echo "==> wait for SSH banner on :2222"
/opt/wait-ssh.sh 127.0.0.1 2222 60

# Settle: let dropbear finish its first-listen and procd quiesce.
sleep 2

echo "==> savevm via monitor"
# Freeze the guest and snapshot. Do NOT quit yet — savevm is async-ish and
# can outlast a fixed sleep on a loaded runner. We poll `info snapshots`
# over the live monitor until boot-state appears (or a deadline) before
# issuing quit, so we never `quit` mid-write.
{
	printf 'stop\n'
	sleep 1
	printf 'savevm boot-state\n'
} | socat - "UNIX-CONNECT:$MON_SOCK"

echo "==> poll 'info snapshots' until boot-state is durable"
snap_ready=0
i=0
while [ "$i" -lt 30 ]; do
	# Fresh monitor connection per probe; reads the snapshot table back.
	if printf 'info snapshots\n' \
		| socat -t1 - "UNIX-CONNECT:$MON_SOCK" 2>/dev/null \
		| grep -q 'boot-state'; then
		snap_ready=1
		break
	fi
	i=$((i + 1))
	sleep 1
done
[ "$snap_ready" = 1 ] || { echo "FAIL: savevm boot-state did not appear in 'info snapshots' within 30s" >&2; exit 1; }

echo "==> quit qemu (snapshot durable)"
printf 'quit\n' | socat -t1 - "UNIX-CONNECT:$MON_SOCK" 2>/dev/null || true

# Wait for qemu to flush the snapshot to qcow2 and exit.
wait "$QEMU_PID" || true
# Reaped; null QEMU_PID so the EXIT trap does not SIGTERM a recycled pid.
QEMU_PID=""

echo "==> verify snapshot present in qcow2"
qemu-img snapshot -l "$QCOW" | grep -E "^\s*[0-9]+\s+boot-state" \
	|| { echo "FAIL: boot-state snapshot not in $QCOW" >&2; exit 1; }

echo "==> snapshot baked: $QCOW"
qemu-img info "$QCOW"
