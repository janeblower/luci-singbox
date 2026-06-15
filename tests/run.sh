#!/bin/sh
# tests/run.sh
set -e
cd "$(dirname "$0")/.."

# Without ucode the suite degrades to a handful of host-only checks (most
# tests SKIP). Re-exec inside the OpenWrt VM so local runs match CI.
# SINGBOX_TESTS_IN_VM=1 is the sentinel set by tests/run-vm.sh (and by
# anyone running on a real OpenWrt host) that breaks the loop.
#
# HOST-COVERAGE NOTE (CI-tests/COV-1): the prod-critical paths — nft -f apply,
# the mkdir-based apply-lock, the rpcd shebang/ubus path — are VM/root-only by
# design (host ucode-mocks once missed the shebang -L bug, per CLAUDE.md). Their
# tests (test_nftables_apply_lock / test_rpcd_prod_path) use fixed `sleep 1`
# windows, a mild timing-flake risk on a loaded runner; harden to condition-
# polling (FIFO/sentinel for the lock, `ubus list | grep singbox-ui` poll for
# rpcd) if they ever flake. There is intentionally NO host-executable substitute.
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
: "${UCODE_APP_LIB_DIR:=$PWD/luci-singbox-ui/root/usr/share/singbox-ui/lib}"
export UCODE_APP_LIB_DIR

echo "==> Shell tests"
# SKIP gate — two independent guards (audit 10.2):
#
#   (A) ucode-gated SKIPs => HARD FAIL, unconditionally. A SKIP line that
#       mentions "ucode" can only come from a test that needs the interpreter
#       and didn't find it — i.e. the degenerate "no coverage masquerading as
#       green" case the gate exists to catch (22+ tests SKIP at once when
#       `ucode` is missing). This is the robust per-category signal the audit
#       asked for: we fail on the SKIPs that indicate a degraded interpreter,
#       NOT on legitimately-absent node/jsonfilter/browser.
#
#   (B) a global SKIP ceiling as defense-in-depth, to catch a NEW degraded
#       dependency we haven't special-cased into (A) yet.
#
# True healthy-VM baseline (recounted 2026-06-12, audit 10.2): node is not
# installed in the OpenWrt guest, so all 14 node-gated test files SKIP
# (test_json_import, test_common_notify_js, test_main_js_syntax,
# test_monitoring_js, test_descriptor_form_dynamic_js, test_validators_js,
# test_descriptor_form_js, test_view_state_js, test_status_panel_js,
# test_transport_helper_js, test_share_link_js, test_audit_2_4, test_audit_8_3,
# test_audit_9_3 — one SKIP line each in the VM, since the guest HAS ucode so
# json_import's 2nd ucode-gated SKIP does not fire). The count grew from 11 to
# 14 as parallel audit work added node-gated units (test_audit_2_4 / _8_3 /
# _9_3); recount with `grep -lE 'NODE_BIN|node ' tests/test_*.sh` and drop the
# ucode-gated false positive test_sharelink_parsers (matches "node1" test data,
# not a node gate). test_browser also SKIPs in the VM. The real built bbolt
# binary is absent in a stock guest, so test_audit_10_5_bbolt_golden SKIPs too.
# That is ~16 legitimate SKIPs (14 node + browser + bbolt-golden). A few
# env-gated tests (nftables_emit on `nft -c` unavailable, migration_drop on
# missing uci, acl_coverage without jsonfilter) can add 1-3 more, so the
# realistic worst-case healthy-VM baseline is ~19. We keep the ceiling at 25
# (documented headroom of ~6 over the ~19 worst-case baseline), and rely on
# guard (A) — not the line count — to catch the degenerate ucode-missing case
# (which trips (A) on the very first ucode SKIP). See spec S5-3 and audit 10.2.
#
# KNOWN LIMITATION (CI-tests/SKIP-1): guard (B) is a moving target — every new
# node-gated *_js test legitimately SKIPs in the VM and eats one slot, so the
# ceiling has crept (15 -> 25) and the headroom over the healthy baseline keeps
# shrinking. The robust signal is guard (A) (any ucode SKIP -> hard fail) plus
# the per-reason classification it embodies. If (B) ever needs to grow again,
# prefer DECOUPLING expected SKIPs from the anomaly budget — sum only SKIPs that
# do NOT match a known-benign allowlist (node|browser|bbolt|apk-tools|git|
# jsonfilter) and gate that residual at a small fixed number — rather than
# bumping the raw ceiling further. Left as-is for now (ceiling 25) to avoid
# changing gate behaviour; the central "doc says 15" mismatch is fixed elsewhere.
MAX_SKIPS="${SINGBOX_MAX_SKIPS:-25}"
skip_total=0
ucode_skips=0
failed=""
fail_count=0
for t in tests/test_*.sh; do
  [ -e "$t" ] || continue
  echo "-- $t"
  # Capture output so we can both show it and count SKIP lines.
  #
  # IMPORTANT: under POSIX/dash/ash with `set -e` active, a failing command
  # substitution in a *simple assignment* (`out=$(sh "$t")`) terminates the
  # shell IMMEDIATELY, before `rc=$?` runs — so `out=$(...); rc=$?` would
  # never print the failing test's output (it is swallowed). We therefore
  # bracket the capture with `set +e` / `set -e`, snapshot `$?`, and print the
  # output unconditionally.
  set +e
  out=$(sh "$t" 2>&1)
  rc=$?
  set -e
  printf '%s\n' "$out"
  # Failure-COLLECTION (not fail-fast): record the failing test and keep going,
  # so one VM run surfaces ALL failures instead of forcing N serial re-runs
  # (each a full ~minutes-long VM boot). We still exit non-zero at the end.
  if [ "$rc" -ne 0 ]; then
    echo "   ^ FAILED ($t, exit $rc)"
    failed="$failed $t"
    fail_count=$((fail_count + 1))
  fi
  # Count SKIP lines. Use `grep -cE` (ERE): a SKIP marker is either a line
  # starting with SKIP (optionally indented) or any line containing "SKIP:".
  # NOTE: `-E` is REQUIRED — with POSIX BRE the `|` in `^SKIP|SKIP:` is a
  # literal pipe, so on BusyBox grep (OpenWrt default) the pattern would
  # match nothing and the counter would stay 0, silently defeating the gate.
  skips=$(printf '%s\n' "$out" | grep -E '^[[:space:]]*SKIP|SKIP:') || true
  n=$(printf '%s\n' "$skips" | grep -cE '.' ) || true
  skip_total=$((skip_total + n))
  # Guard (A): any SKIP that mentions "ucode" (case-insensitive) is the
  # degraded-interpreter signal — count it separately and fail hard below.
  un=$(printf '%s\n' "$skips" | grep -ciE 'ucode') || true
  ucode_skips=$((ucode_skips + un))
done

# Report all collected test failures, then abort. Printed before the SKIP
# guards so a real failure is always the headline.
if [ "$fail_count" -gt 0 ]; then
  echo "FAIL: $fail_count test(s) failed:"
  for t in $failed; do echo "  - $t"; done
  exit 1
fi

if [ "$ucode_skips" -gt 0 ]; then
  echo "FAIL: $ucode_skips test(s) SKIPped for a MISSING ucode interpreter —"
  echo "      that is zero real coverage masquerading as green, NOT a pass."
  echo "      Run inside the OpenWrt VM via 'sh tests/run.sh' on a host"
  echo "      without ucode (it auto-delegates to tests/run-vm.sh)."
  exit 1
fi

if [ "$skip_total" -gt "$MAX_SKIPS" ]; then
  echo "FAIL: $skip_total tests SKIPped (>$MAX_SKIPS) — environment is degraded"
  echo "      (a build dependency is likely missing; this is NOT a pass)."
  echo "      Inspect the SKIP lines above, or set SINGBOX_MAX_SKIPS to"
  echo "      override knowingly."
  exit 1
fi

echo "All tests passed. ($skip_total SKIP, threshold $MAX_SKIPS; ucode-gated SKIP=$ucode_skips)"
