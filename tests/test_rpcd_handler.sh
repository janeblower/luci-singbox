#!/bin/sh
# tests/test_rpcd_handler.sh
set -e

H=luci-app-singbox-ui/root/usr/libexec/rpcd/singbox-ui

if [ ! -x "$H" ]; then
  echo "FAIL: $H not present or not executable"; exit 1
fi

# Locate ucode the same way the other ucode tests do. The handler's shebang
# (#!/usr/bin/ucode) is correct for the OpenWrt target but absent on the dev
# box, so we invoke it explicitly through $UCODE_BIN.
if command -v ucode >/dev/null 2>&1; then
	UCODE_BIN=ucode
	UCODE_LIB_FLAGS=""
elif [ -x "${UCODE_BIN:-}" ] && [ -d "${UCODE_STUB_DIR:-}" ]; then
	UCODE_LIB_FLAGS="-L $UCODE_STUB_DIR"
	[ -n "${UCODE_LIB_DIR:-}" ] && UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L $UCODE_LIB_DIR"
else
	echo "SKIP: ucode not available"
	exit 0
fi

# shellcheck disable=SC2086
run_h() { "$UCODE_BIN" $UCODE_LIB_FLAGS "$H" "$@"; }

echo "-- list emits valid JSON with all methods"
out=$(run_h list)
for m in generate nftables restart refresh status read_config; do
	printf "%s\n" "$out" | jq -e ".$m" >/dev/null || { echo "FAIL: missing $m"; exit 1; }
done
printf "%s\n" "$out" | jq -e '.nftables.action' >/dev/null || { echo "FAIL: missing nftables.action"; exit 1; }
printf "%s\n" "$out" | jq -e '.refresh.what'    >/dev/null || { echo "FAIL: missing refresh.what"; exit 1; }

echo "-- call generate dispatches to generate.uc"
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
# Stubs record argv to a sentinel file because run() redirects stdout/stderr.
cat >"$tmpdir/ucode" <<EOF
#!/bin/sh
echo "called ucode with: \$*" >> "$tmpdir/ucode.log"
echo "OK"
EOF
chmod +x "$tmpdir/ucode"
out=$(echo '{}' | PATH="$tmpdir:$PATH" run_h call generate)
printf "%s\n" "$out" | jq -e '.status == "ok"' >/dev/null || { echo "FAIL: generate did not return ok"; cat "$tmpdir/ucode.log" 2>/dev/null; exit 1; }
grep -q "generate.uc" "$tmpdir/ucode.log" || { echo "FAIL: generate.uc not invoked"; cat "$tmpdir/ucode.log" 2>/dev/null; exit 1; }

echo "-- call nftables apply dispatches to NFTABLES_CMD"
cat >"$tmpdir/nftables.sh" <<EOF
#!/bin/sh
echo "called nftables with: \$*" >> "$tmpdir/nftables.log"
EOF
chmod +x "$tmpdir/nftables.sh"
out=$(echo '{"action":"apply"}' | NFTABLES_CMD="$tmpdir/nftables.sh" run_h call nftables)
printf "%s\n" "$out" | jq -e '.status == "ok"' >/dev/null || { echo "FAIL: nftables apply did not return ok"; cat "$tmpdir/nftables.log" 2>/dev/null; exit 1; }
grep -q "called nftables with: apply" "$tmpdir/nftables.log" || { echo "FAIL: nftables.sh not invoked with apply"; cat "$tmpdir/nftables.log" 2>/dev/null; exit 1; }

echo "-- call nftables with bad action returns error"
out=$(echo '{"action":"haxx"}' | NFTABLES_CMD="$tmpdir/nftables.sh" run_h call nftables)
printf "%s\n" "$out" | jq -e '.status == "error"' >/dev/null || { echo "FAIL: bad action should return error"; exit 1; }

echo "-- call restart with stubbed init.d returns ok"
out=$(echo '{}' | SINGBOX_INIT=true run_h call restart)
printf "%s\n" "$out" | jq -e '.status == "ok"' >/dev/null || { echo "FAIL: restart with stub did not return ok"; exit 1; }

echo "-- call restart with failing init.d returns error"
out=$(echo '{}' | SINGBOX_INIT=false run_h call restart)
printf "%s\n" "$out" | jq -e '.status == "error"' >/dev/null || { echo "FAIL: failing restart should return error"; exit 1; }

echo "-- call read_config with missing file returns error"
out=$(echo '{}' | SINGBOX_CONFIG=/nonexistent/path run_h call read_config)
printf "%s\n" "$out" | jq -e '.status == "error"' >/dev/null || { echo "FAIL: missing config should return error"; exit 1; }

echo "-- call read_config returns file contents"
echo '{"hello":"world"}' >"$tmpdir/config.json"
out=$(echo '{}' | SINGBOX_CONFIG="$tmpdir/config.json" run_h call read_config)
printf "%s\n" "$out" | jq -e '.status == "ok"' >/dev/null || { echo "FAIL: read_config should return ok"; exit 1; }
printf "%s\n" "$out" | jq -re '.content' | grep -q '"hello":"world"' || { echo "FAIL: read_config content mismatch"; exit 1; }

echo "-- call status returns ok with empty lists when tmpdir missing"
out=$(echo '{}' | SINGBOX_TMP=/nonexistent/path run_h call status)
printf "%s\n" "$out" | jq -e '.status == "ok"' >/dev/null || { echo "FAIL: status should return ok"; exit 1; }
printf "%s\n" "$out" | jq -e '.subscriptions | length == 0' >/dev/null || { echo "FAIL: subscriptions should be empty"; exit 1; }
printf "%s\n" "$out" | jq -e '.rulesets      | length == 0' >/dev/null || { echo "FAIL: rulesets should be empty"; exit 1; }

echo "-- call status picks up sub_*.txt and rs_*.json"
mkdir -p "$tmpdir/state"
: >"$tmpdir/state/sub_alpha.txt"
: >"$tmpdir/state/rs_beta.json"
out=$(echo '{}' | SINGBOX_TMP="$tmpdir/state" run_h call status)
printf "%s\n" "$out" | jq -e '.subscriptions[0].name == "alpha"' >/dev/null || { echo "FAIL: subscription alpha not found"; exit 1; }
printf "%s\n" "$out" | jq -e '.rulesets[0].name == "beta"'       >/dev/null || { echo "FAIL: ruleset beta not found"; exit 1; }

echo "-- call status does not leak pgrep stdout (regression: corrupted JSON)"
# pgrep prints matching PIDs to stdout. is_singbox_running() must redirect that
# away or ubus parses the leading noise + JSON as garbage and bails with
# "Invalid argument". Stub pgrep to a noisy child and assert one clean line.
cat >"$tmpdir/pgrep" <<'EOF'
#!/bin/sh
echo "12345"
echo "stderr-noise" >&2
exit 0
EOF
chmod +x "$tmpdir/pgrep"
raw=$(echo '{}' | PATH="$tmpdir:$PATH" SINGBOX_TMP=/nonexistent/path run_h call status)
# Command substitution strips trailing newlines; a clean response is one JSON
# line, so $raw must contain no embedded newlines. A leaked PID would show up
# as a line BEFORE the JSON.
case "$raw" in
	*"
"*) echo "FAIL: status output has embedded newline (likely pgrep PID leak); raw=[$raw]"; exit 1 ;;
esac
case "$raw" in
	"{"*) ;;
	*) echo "FAIL: status output does not start with '{'; raw=[$raw]"; exit 1 ;;
esac
printf "%s\n" "$raw" | jq -e '.status == "ok" and .running == true' >/dev/null \
	|| { echo "FAIL: status not ok or running=true; raw=[$raw]"; exit 1; }

echo "-- call status reports running=false when pgrep finds nothing"
cat >"$tmpdir/pgrep" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$tmpdir/pgrep"
raw=$(echo '{}' | PATH="$tmpdir:$PATH" SINGBOX_TMP=/nonexistent/path run_h call status)
printf "%s\n" "$raw" | jq -e '.running == false' >/dev/null \
	|| { echo "FAIL: running should be false; raw=[$raw]"; exit 1; }

echo "-- call refresh with invalid what returns error"
out=$(echo '{"what":"haxx"}' | run_h call refresh)
printf "%s\n" "$out" | jq -e '.status == "error"' >/dev/null || { echo "FAIL: invalid what should return error"; exit 1; }

echo "-- call refresh dispatches to subscription.uc"
# Replace stub from earlier in the file (which writes "OK" not invocation log).
cat >"$tmpdir/ucode" <<EOF
#!/bin/sh
echo "called ucode with: \$*" >> "$tmpdir/refresh.log"
EOF
chmod +x "$tmpdir/ucode"
out=$(echo '{"what":"all"}' | PATH="$tmpdir:$PATH" run_h call refresh)
printf "%s\n" "$out" | jq -e '.status == "ok"' >/dev/null || { echo "FAIL: refresh did not return ok"; cat "$tmpdir/refresh.log" 2>/dev/null; exit 1; }
grep -q "refresh all force" "$tmpdir/refresh.log" || { echo "FAIL: subscription.uc not invoked with refresh all force"; cat "$tmpdir/refresh.log" 2>/dev/null; exit 1; }

echo "-- call with unknown method returns error"
out=$(echo '{}' | run_h call frobnicate)
printf "%s\n" "$out" | jq -e '.status == "error"' >/dev/null || { echo "FAIL: unknown method should return error"; exit 1; }

echo "-- run() redirects both stdout and stderr"
# Use a stub ucode that writes to stderr; that text must NOT appear in the
# JSON we emit. Drive a `call generate` and inspect stdout for a clean JSON.
cat >"$tmpdir/ucode" <<'EOF'
#!/bin/sh
echo "stderr-noise" >&2
echo "stdout-noise"
exit 0
EOF
chmod +x "$tmpdir/ucode"
out=$(echo '{}' | PATH="$tmpdir:$PATH" run_h call generate 2>/dev/null)
echo "$out" | grep -q 'stderr-noise' && { echo "FAIL: stderr leaked into response"; exit 1; }
echo "$out" | grep -q 'stdout-noise' && { echo "FAIL: stdout leaked into response"; exit 1; }
printf "%s\n" "$out" | jq -e '.status == "ok"' >/dev/null || { echo "FAIL: status not ok"; exit 1; }
echo "  PASS: stderr+stdout suppressed"

echo "OK"
