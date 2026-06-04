#!/bin/sh
# tests/run-docker.sh
#
# Spin up the same OpenWrt rootfs image CI uses and run tests/run.sh inside
# it. This gives developers on Linux/macOS the full test suite locally —
# ucode, uci, nft and the apk-installed sing-box binary — instead of the
# host-only subset (most tests SKIP without these tools).
#
# CI invokes this same script, so there is one definition of "the test env"
# and no drift between local and GitHub Actions.

set -eu
cd "$(dirname "$0")/.."

: "${OPENWRT_TAG:=x86_64-25.12.3}"
IMAGE="openwrt/rootfs:${OPENWRT_TAG}"

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker not found in PATH." >&2
  echo "       Install Docker, or run tests directly on an OpenWrt host" >&2
  echo "       with SINGBOX_TESTS_IN_DOCKER=1 sh tests/run.sh" >&2
  exit 1
fi

# Persistent apk cache so `apk add sing-box` (~10 MB) only downloads once
# across runs. CI gets a fresh runner each time so this is a no-op there,
# but locally it cuts iteration time from ~30 s to ~3 s.
APK_CACHE="${SINGBOX_TESTS_APK_CACHE:-$HOME/.cache/luci-app-singbox-ui/apk-cache}"
mkdir -p "$APK_CACHE"

echo "==> Running tests inside ${IMAGE} (apk cache: ${APK_CACHE})"

exec docker run --rm \
  -v "$PWD:/work" -w /work \
  -v "$APK_CACHE:/etc/apk/cache" \
  -e SINGBOX_TESTS_IN_DOCKER=1 \
  "$IMAGE" \
  sh -ec '
    apk update >/dev/null 2>&1
    apk add sing-box >/dev/null 2>&1
    sh tests/run.sh
  '
