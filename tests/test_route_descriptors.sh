#!/bin/sh
# tests/test_route_descriptors.sh — registry accepts route_rule/rule_set kinds
# and the new dynamic sources; descriptors register and materialize.
set -eu
cd "$(dirname "$0")/.."
UCODE_BIN="${UCODE_BIN:-ucode}"
LIB="${UCODE_LIB_DIR:-luci-singbox-ui/root/usr/share/singbox-ui/lib}"
command -v "$UCODE_BIN" >/dev/null 2>&1 || { echo "SKIP test_route_descriptors (ucode missing)"; exit 0; }

out=$("$UCODE_BIN" -L "$LIB" -e '
  let reg = require("builder.protocols.registry");
  // kind allowlist
  reg.register({ kind:"route_rule", type:"probe", sing_box_type:"",
                 fields:[{name:"x",type:"string",tab:"match",json_key:"x"}] });
  reg.register({ kind:"rule_set", type:"probe", sing_box_type:"probe",
                 fields:[{name:"y",type:"string",tab:"basic",json_key:"y"}] });
  // dynamic sources
  reg.register({ kind:"route_rule", type:"probe2", sing_box_type:"",
                 fields:[{name:"z",type:"list",tab:"match",dynamic:"rulesets"},
                         {name:"w",type:"list",tab:"match",dynamic:"route_rules"}] });
  let m = reg.materialize("route_rule","probe");
  print((m != null && m.kind === "route_rule") ? "OK\n" : "BAD\n");
')
echo "$out"
echo "$out" | grep -q '^OK$' || { echo "FAIL"; exit 1; }
echo "test_route_descriptors: PASS"
