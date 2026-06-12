#!/bin/sh
# tests/run-vm.sh — local + CI entry that boots the published
# openwrt-test image and runs the suite inside the OpenWrt guest.
#
# This is the long-form sibling of tests/run.sh, called automatically
# when run.sh detects it's not already inside the VM.
#
# Image override: set SINGBOX_TEST_IMAGE to use a local tag (e.g. for
# Phase 1 development before the image is published).
set -eu
cd "$(dirname "$0")/.."

IMAGE="${SINGBOX_TEST_IMAGE:-ghcr.io/janeblower/luci-singbox/openwrt-test:latest}"

if ! command -v docker >/dev/null 2>&1; then
	echo "ERROR: docker not found in PATH." >&2
	echo "       Install Docker, or run tests directly on an OpenWrt host" >&2
	echo "       with SINGBOX_TESTS_IN_VM=1 sh tests/run.sh" >&2
	exit 1
fi

if [ ! -w /dev/kvm ]; then
	echo "ERROR: /dev/kvm not writable." >&2
	echo "       The test rig needs KVM acceleration; TCG fallback is intentionally not" >&2
	echo "       supported (see docs/superpowers/specs/2026-06-09-unified-qemu-test-rig-design.md §2.8)." >&2
	echo "       Fix locally: sudo chmod 0666 /dev/kvm" >&2
	exit 1
fi

# Pull on demand. Docker caches layers, so subsequent runs are near-free.
# Bounded retry (audit 10.6): a registry blip or a slow GHCR on a loaded CI
# runner must not fail the whole job on the first transient. Three attempts
# with 2s/4s/8s backoff; only the final failure is fatal.
pull_image() {
	attempt=1
	delay=2
	while :; do
		if docker pull "$IMAGE" >/dev/null; then
			return 0
		fi
		if [ "$attempt" -ge 3 ]; then
			echo "ERROR: docker pull '$IMAGE' failed after 3 attempts." >&2
			return 1
		fi
		echo "WARN: docker pull failed (attempt $attempt/3), retrying in ${delay}s..." >&2
		sleep "$delay"
		attempt=$((attempt + 1))
		delay=$((delay * 2))
	done
}
pull_image

echo "==> running tests inside $IMAGE"
exec docker run --rm \
	--device /dev/kvm \
	-v "$PWD:/work" \
	-e "KEEP_VM=${KEEP_VM:-0}" \
	"$IMAGE"
