#!/bin/sh
set -eu
. "$(dirname "$0")/lib/sb_helpers.sh"
LIB="${SB_LIB}"
UCODE="${UCODE_BIN:-ucode}"
command -v "$UCODE" >/dev/null 2>&1 || { echo "SKIP: no ucode"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/t.uc" <<'UC'
let sd = require("builder.protocols.schema_dump");
let found = false;
for (let k in sd.FIELD_WHITELIST) if (k === "max_version") found = true;
if (!found) { print("FAIL: max_version not whitelisted\n"); exit(1); }
let all = sd.dump_all();
for (let k in [ "cache", "clash_api", "dns_rule" ])
  if (!(k in all)) { print(sprintf("FAIL: dump_all missing %s\n", k)); exit(1); }
print("OK\n");
UC
out="$("$UCODE" -L "$LIB" "$WORK/t.uc" 2>&1)"
echo "$out" | grep -q "OK" || { echo "FAIL: $out"; exit 1; }
echo "PASS"
