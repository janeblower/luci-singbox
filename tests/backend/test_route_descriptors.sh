#!/bin/sh
# tests/test_route_descriptors.sh — registry accepts route_rule/rule_set kinds
# and the new dynamic sources; descriptors register and materialize.
set -eu
. "$(dirname "$0")/../lib/sb_helpers.sh"
cd "$(dirname "$0")/../.."
UCODE_BIN="${UCODE_BIN:-ucode}"
LIB="${UCODE_LIB_DIR:-${SB_LIB}}"
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

out2=$("$UCODE_BIN" -L "$LIB" -e '
  let reg = require("builder.route.registry");   // eager-loads all 5 descriptors
  let ok = true;
  for (let t in ["default","logical"]) ok = ok && (reg.get("route_rule", t) != null);
  for (let t in ["remote","local","inline"]) ok = ok && (reg.get("rule_set", t) != null);
  let m = reg.materialize("route_rule","default");
  let names = {}; for (let f in m.fields) names[f.name] = 1;
  ok = ok && names["domain_suffix"] && names["action"] && names["outbound"];
  ok = ok && names["_show_advanced_match"] && names["_show_advanced_action"];
  let ml = reg.materialize("route_rule","logical");
  let ln = {}; for (let f in ml.fields) ln[f.name] = 1;
  ok = ok && ln["mode"] && ln["rules"] && ln["action"];
  print(ok ? "OK2\n" : "BAD2\n");
')
echo "$out2"
echo "$out2" | grep -q '^OK2$' || { echo "FAIL descriptors"; exit 1; }
echo "test_route_descriptors(real): PASS"

out3=$("$UCODE_BIN" -L "$LIB" -e '
  let h = require("builder.route.headless");
  let obj = h.build({ [".name"]:"x", domain_suffix: ["example.com"], rule_set: ["my_rs"], inbound: ["tun0"] });
  let ok = (obj["domain_suffix"] != null) && (obj["rule_set"] == null) &&
           (obj["inbound"] == null) && (obj["type"] == null) && (obj["tag"] == null);
  print(ok ? "OK3\n" : sprintf("BAD3 %J\n", obj));
')
echo "$out3"
echo "$out3" | grep -q "^OK3$" || { echo "FAIL headless"; exit 1; }
echo "test_route_descriptors(headless): PASS"
