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
cat >"$tmpdir/ucode" <<'EOF'
#!/bin/sh
echo "called ucode with: $*" >&2
echo "OK"
EOF
chmod +x "$tmpdir/ucode"
out=$(echo '{}' | PATH="$tmpdir:$PATH" run_h call generate 2>"$tmpdir/err")
printf "%s\n" "$out" | jq -e '.status == "ok"' >/dev/null || { echo "FAIL: generate did not return ok"; cat "$tmpdir/err"; exit 1; }
grep -q "generate.uc" "$tmpdir/err" || { echo "FAIL: generate.uc not invoked"; cat "$tmpdir/err"; exit 1; }

echo "-- call nftables apply dispatches to NFTABLES_CMD"
cat >"$tmpdir/nftables.sh" <<'EOF'
#!/bin/sh
echo "called nftables with: $*" >&2
EOF
chmod +x "$tmpdir/nftables.sh"
out=$(echo '{"action":"apply"}' | NFTABLES_CMD="$tmpdir/nftables.sh" run_h call nftables 2>"$tmpdir/err2")
printf "%s\n" "$out" | jq -e '.status == "ok"' >/dev/null || { echo "FAIL: nftables apply did not return ok"; cat "$tmpdir/err2"; exit 1; }
grep -q "called nftables with: apply" "$tmpdir/err2" || { echo "FAIL: nftables.sh not invoked with apply"; cat "$tmpdir/err2"; exit 1; }

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

echo "-- call refresh with invalid what returns error"
out=$(echo '{"what":"haxx"}' | run_h call refresh)
printf "%s\n" "$out" | jq -e '.status == "error"' >/dev/null || { echo "FAIL: invalid what should return error"; exit 1; }

echo "-- call refresh dispatches to subscription.uc"
out=$(echo '{"what":"all"}' | PATH="$tmpdir:$PATH" run_h call refresh 2>"$tmpdir/err3")
printf "%s\n" "$out" | jq -e '.status == "ok"' >/dev/null || { echo "FAIL: refresh did not return ok"; cat "$tmpdir/err3"; exit 1; }
grep -q "refresh all force" "$tmpdir/err3" || { echo "FAIL: subscription.uc not invoked with refresh all force"; cat "$tmpdir/err3"; exit 1; }

echo "-- call with unknown method returns error"
out=$(echo '{}' | run_h call frobnicate)
printf "%s\n" "$out" | jq -e '.status == "error"' >/dev/null || { echo "FAIL: unknown method should return error"; exit 1; }

echo "OK"
