#!/bin/sh
# tests/docker/wait-ssh.sh — poll an SSH endpoint until it accepts
# connections, with a deadline. Used by entrypoint.sh after qemu loadvm
# and by build-snapshot.sh after the first cold boot.
#
# Usage: wait-ssh.sh HOST PORT [DEADLINE_SECONDS]
set -eu

HOST="${1:?host required}"
PORT="${2:?port required}"
DEADLINE="${3:-30}"

i=0
while [ "$i" -lt "$DEADLINE" ]; do
	# Use bash /dev/tcp would be nice but this is /bin/sh. Use nc -z.
	if nc -z "$HOST" "$PORT" 2>/dev/null; then
		# nc -z returns when the port accepts a TCP handshake. We also
		# want to see the SSH banner before claiming the daemon is
		# ready, because nc -z passes even during early SSH startup
		# when the daemon doesn't yet read input.
		banner=$(echo "" | nc -w 2 "$HOST" "$PORT" 2>/dev/null | head -c 4 || true)
		case "$banner" in
			SSH-*) exit 0 ;;
		esac
	fi
	i=$((i + 1))
	sleep 1
done

echo "wait-ssh: ${HOST}:${PORT} not ready after ${DEADLINE}s" >&2
exit 1
