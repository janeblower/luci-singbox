#!/bin/sh
set -eu
. "$(dirname "$0")/lib/sb_helpers.sh"
LIB="${SB_LIB}"
UCODE="${UCODE_BIN:-ucode}"
command -v "$UCODE" >/dev/null 2>&1 || { echo "SKIP: no ucode"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/t.uc" <<'UC'
let reg = require("builder.protocols.registry");
// registry must accept dynamic:"dns_rules" without throwing.
reg.register({ kind: "dns_rule", type: "tdyn", sing_box_type: "",
  fields: [ { name: "rules", type: "list", tab: "match", dynamic: "dns_rules", ui_label: "Sub" } ] });
print("OK\n");
UC
out="$("$UCODE" -L "$LIB" "$WORK/t.uc" 2>&1)" || { echo "FAIL: $out"; exit 1; }
echo "$out" | grep -q OK || { echo "FAIL: $out"; exit 1; }
echo "PASS"
