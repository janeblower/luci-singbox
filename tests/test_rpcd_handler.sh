#!/bin/sh
# tests/test_rpcd_handler.sh
set -e

H=luci-app-singbox-ui/root/usr/libexec/rpcd/singbox-ui

if [ ! -x "$H" ]; then
  echo "FAIL: $H not present or not executable"; exit 1
fi

echo "-- shellcheck"
shellcheck -s sh "$H"

echo "-- list emits valid JSON with both methods"
out=$("$H" list)
echo "$out" | jq -e '.generate' >/dev/null || { echo "FAIL: missing generate"; exit 1; }
echo "$out" | jq -e '.nftables.action' >/dev/null || { echo "FAIL: missing nftables.action"; exit 1; }

echo "-- call generate dispatches to generate.uc"
# Stub the path so we can assert it was invoked. Use a wrapper script.
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
cat >"$tmpdir/ucode" <<'EOF'
#!/bin/sh
echo "called ucode with: $*" >&2
echo "OK"
EOF
chmod +x "$tmpdir/ucode"
PATH="$tmpdir:$PATH" out=$(echo '{}' | "$H" call generate 2>"$tmpdir/err")
echo "$out" | jq -e '.status == "ok"' >/dev/null || { echo "FAIL: generate did not return ok"; cat "$tmpdir/err"; exit 1; }
grep -q "generate.uc" "$tmpdir/err" || { echo "FAIL: generate.uc not invoked"; cat "$tmpdir/err"; exit 1; }

echo "-- call nftables apply dispatches to nftables.sh"
cat >"$tmpdir/nftables.sh" <<'EOF'
#!/bin/sh
echo "called nftables with: $*" >&2
EOF
chmod +x "$tmpdir/nftables.sh"
out=$(echo '{"action":"apply"}' | NFTABLES_SH="$tmpdir/nftables.sh" "$H" call nftables 2>"$tmpdir/err2")
echo "$out" | jq -e '.status == "ok"' >/dev/null || { echo "FAIL: nftables apply did not return ok"; cat "$tmpdir/err2"; exit 1; }
grep -q "called nftables with: apply" "$tmpdir/err2" || { echo "FAIL: nftables.sh not invoked with apply"; cat "$tmpdir/err2"; exit 1; }

echo "-- call nftables with bad action returns error"
out=$(echo '{"action":"haxx"}' | NFTABLES_SH="$tmpdir/nftables.sh" "$H" call nftables)
echo "$out" | jq -e '.status == "error"' >/dev/null || { echo "FAIL: bad action should return error"; exit 1; }

echo "-- list includes restart method"
out=$("$H" list)
echo "$out" | jq -e '.restart' >/dev/null || { echo "FAIL: missing restart in list"; exit 1; }

echo "-- call restart with stubbed init.d returns ok"
out=$(echo '{}' | SINGBOX_INIT=true "$H" call restart)
echo "$out" | jq -e '.status == "ok"' >/dev/null || { echo "FAIL: restart with stub did not return ok"; exit 1; }

echo "-- call restart with failing init.d returns error"
out=$(echo '{}' | SINGBOX_INIT=false "$H" call restart)
echo "$out" | jq -e '.status == "error"' >/dev/null || { echo "FAIL: failing restart should return error"; exit 1; }

echo "OK"
