#!/bin/sh
# tests/test_rpcd_handler.sh
set -e

H=root/usr/libexec/rpcd/sing-box

if [ ! -x "$H" ]; then
  echo "FAIL: $H not present or not executable"; exit 1
fi

echo "-- shellcheck"
shellcheck -s sh "$H"

echo "-- list emits valid JSON with both methods"
out=$("$H" list)
echo "$out" | jq -e '.generate' >/dev/null || { echo "FAIL: missing generate"; exit 1; }
echo "$out" | jq -e '.nftables.action' >/dev/null || { echo "FAIL: missing nftables.action"; exit 1; }

echo "-- call generate dispatches to generate.lua"
# Stub the path so we can assert it was invoked. Use a wrapper script.
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
cat >"$tmpdir/lua" <<'EOF'
#!/bin/sh
echo "called lua with: $*" >&2
echo "OK"
EOF
chmod +x "$tmpdir/lua"
PATH="$tmpdir:$PATH" out=$(echo '{}' | "$H" call generate 2>"$tmpdir/err")
echo "$out" | jq -e '.status == "ok"' >/dev/null || { echo "FAIL: generate did not return ok"; cat "$tmpdir/err"; exit 1; }
grep -q "generate.lua" "$tmpdir/err" || { echo "FAIL: generate.lua not invoked"; cat "$tmpdir/err"; exit 1; }

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

echo "OK"
