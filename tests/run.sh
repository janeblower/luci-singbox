#!/bin/sh
# tests/run.sh
set -e
cd "$(dirname "$0")/.."

# Without ucode the suite degrades to a handful of host-only checks (most
# tests SKIP). Re-exec inside the OpenWrt rootfs container so local runs
# match CI. SINGBOX_TESTS_IN_DOCKER=1 is the sentinel set by run-docker.sh
# (and by anyone running on a real OpenWrt host) that breaks the loop.
if [ "${SINGBOX_TESTS_IN_DOCKER:-0}" != "1" ] && ! command -v ucode >/dev/null 2>&1; then
  echo "==> ucode not found on host; delegating to tests/run-docker.sh"
  echo "    (set SINGBOX_TESTS_IN_DOCKER=1 to bypass and run the host-only subset)"
  exec sh "$(dirname "$0")/run-docker.sh" "$@"
fi

# If UCODE_BIN/UCODE_LIB_DIR are set by the caller (e.g. CI), pass them
# through to each shell test. UCODE_STUB_DIR defaults to the in-tree stubs.
: "${UCODE_STUB_DIR:=$PWD/tests/ucode-stubs}"
export UCODE_STUB_DIR
[ -n "${UCODE_BIN:-}" ] && export UCODE_BIN
[ -n "${UCODE_LIB_DIR:-}" ] && export UCODE_LIB_DIR
: "${UCODE_APP_LIB_DIR:=$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/lib}"
export UCODE_APP_LIB_DIR

echo "==> Shell tests"
for t in tests/test_*.sh; do
  [ -e "$t" ] || continue
  echo "-- $t"
  sh "$t"
done

echo "All tests passed."
