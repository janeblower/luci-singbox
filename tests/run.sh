#!/bin/sh
# tests/run.sh
set -e
cd "$(dirname "$0")/.."

# Without ucode the suite degrades to a handful of host-only checks (most
# tests SKIP). Re-exec inside the OpenWrt VM so local runs match CI.
# SINGBOX_TESTS_IN_VM=1 is the sentinel set by tests/run-vm.sh (and by
# anyone running on a real OpenWrt host) that breaks the loop.
if [ "${SINGBOX_TESTS_IN_VM:-0}" != "1" ] && ! command -v ucode >/dev/null 2>&1; then
  echo "==> ucode not found on host; delegating to tests/run-vm.sh"
  echo "    (set SINGBOX_TESTS_IN_VM=1 to bypass and run the host-only subset)"
  exec sh "$(dirname "$0")/run-vm.sh" "$@"
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
# Max number of SKIP lines tolerated across the whole suite. A healthy VM run
# (CI's real path) ALREADY produces ~6 legitimate SKIPs: node is not installed
# in the OpenWrt guest, so the 5 node-gated tests SKIP (test_descriptor_form_js,
# test_main_js_syntax, test_validators_js, test_share_link_js, test_json_import),
# plus test_browser always SKIPs inside the VM. A few more are conditionally
# env-gated (test_acl_coverage without jsonfilter, test_nftables_emit when
# `nft -c` is unavailable, test_migration_drop_removed). That puts a healthy run
# around 6-9 SKIPs. When `ucode` is missing instead, 22+ ucode-gated tests SKIP
# at once (~28+ SKIP lines) — zero real coverage masquerading as green, which we
# must fail. Threshold 15 sits well above the healthy ceiling (~9, leaving
# headroom for future env-gated tests) and far below the degenerate ~28+.
# See spec S5-3. NOTE: the plan's literal 5 would FAIL a healthy VM run (it
# under-counted the node-gated *_js* tests), so we raise it to 15 here.
MAX_SKIPS="${SINGBOX_MAX_SKIPS:-15}"
skip_total=0
for t in tests/test_*.sh; do
  [ -e "$t" ] || continue
  echo "-- $t"
  # Capture output so we can both show it and count SKIP lines.
  #
  # IMPORTANT: under POSIX/dash/ash with `set -e` active, a failing command
  # substitution in a *simple assignment* (`out=$(sh "$t")`) terminates the
  # shell IMMEDIATELY, before `rc=$?` runs — so `out=$(...); rc=$?` would
  # never print the failing test's output (it is swallowed). We therefore
  # bracket the capture with `set +e` / `set -e`, snapshot `$?`, print the
  # output unconditionally, and only then re-assert failure with an explicit
  # `exit "$rc"`. This both shows the failing test's output AND aborts.
  set +e
  out=$(sh "$t" 2>&1)
  rc=$?
  set -e
  printf '%s\n' "$out"
  [ "$rc" -eq 0 ] || exit "$rc"
  # Count SKIP lines. Use `grep -cE` (ERE): a SKIP marker is either a line
  # starting with SKIP (optionally indented) or any line containing "SKIP:".
  # NOTE: `-E` is REQUIRED — with POSIX BRE the `|` in `^SKIP|SKIP:` is a
  # literal pipe, so on BusyBox grep (OpenWrt default) the pattern would
  # match nothing and the counter would stay 0, silently defeating the gate.
  n=$(printf '%s\n' "$out" | grep -cE '^[[:space:]]*SKIP|SKIP:') || true
  skip_total=$((skip_total + n))
done

if [ "$skip_total" -gt "$MAX_SKIPS" ]; then
  echo "FAIL: $skip_total tests SKIPped (>$MAX_SKIPS) — environment is degraded"
  echo "      (ucode/jsonfilter likely missing; this is NOT a pass)."
  echo "      Run inside the OpenWrt VM via 'sh tests/run.sh' on a host"
  echo "      without ucode, or set SINGBOX_MAX_SKIPS to override knowingly."
  exit 1
fi

echo "All tests passed. ($skip_total SKIP, threshold $MAX_SKIPS)"
