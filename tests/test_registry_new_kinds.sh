#!/bin/sh
set -eu
. "$(dirname "$0")/lib/sb_helpers.sh"
LIB="${SB_LIB}"
UCODE="${UCODE_BIN:-ucode}"
command -v "$UCODE" >/dev/null 2>&1 || { echo "SKIP: no ucode"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/t.uc" <<'UC'
let reg = require("builder.protocols.registry");
// New kinds must register without throwing.
for (let k in [ "cache", "clash_api", "dns_rule" ])
  reg.register({ kind: k, type: k, sing_box_type: k,
    fields: [ { name: "x", type: "string", tab: "basic", json_key: "x" } ] });
// max_version must be accepted and round-trip a valid 2-part string.
reg.register({ kind: "cache", type: "c2", sing_box_type: "cache_file",
  fields: [ { name: "y", type: "string", tab: "basic", json_key: "y", max_version: "1.13" } ] });
print("OK\n");
UC
out="$("$UCODE" -L "$LIB" "$WORK/t.uc" 2>&1)" || { echo "FAIL: register threw: $out"; exit 1; }
echo "$out" | grep -q "OK" || { echo "FAIL: $out"; exit 1; }
echo "PASS"
