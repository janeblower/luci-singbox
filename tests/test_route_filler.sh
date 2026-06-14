#!/bin/sh
# tests/test_route_filler.sh — filler builds a route_rule body with no type/tag
# header, num_array coercion, and array-valued requires gating.
set -eu
cd "$(dirname "$0")/.."
UCODE_BIN="${UCODE_BIN:-ucode}"
LIB="${UCODE_LIB_DIR:-luci-singbox-ui/root/usr/share/singbox-ui/lib}"
command -v "$UCODE_BIN" >/dev/null 2>&1 || { echo "SKIP test_route_filler (ucode missing)"; exit 0; }

out=$("$UCODE_BIN" -L "$LIB" -e '
  let filler = require("builder._filler");
  let d = { kind:"route_rule", sing_box_type:"",
    fields:[
      { name:"port", type:"list", json_key:"port", coerce:"num_array", tab:"match" },
      { name:"domain_suffix", type:"list", json_key:"domain_suffix", coerce:"array", tab:"match" },
      { name:"action", type:"enum", json_key:"action", omit_when:"never", tab:"action" },
      { name:"outbound", type:"string", json_key:"outbound", tab:"action",
        requires:{ field:"action", value:["route","route-options"] } },
    ] };
  let s = { [".name"]:"r1", port:["443","bad","80"], domain_suffix:"example.com",
            action:"route", outbound:"proxy" };
  let o = filler.build(d, s);
  let ok = (o.type == null && o.tag == null);
  ok = ok && (length(o.port) === 2 && o.port[0] === 443 && o.port[1] === 80);
  ok = ok && (type(o.domain_suffix) === "array" && o.domain_suffix[0] === "example.com");
  ok = ok && (o.outbound === "proxy");
  let s2 = { [".name"]:"r2", action:"reject", outbound:"proxy" };
  let o2 = filler.build(d, s2);
  ok = ok && (o2.outbound == null && o2.action === "reject");
  print(ok ? "OK\n" : sprintf("BAD %J / %J\n", o, o2));
')
echo "$out"
echo "$out" | grep -q '^OK$' || { echo "FAIL"; exit 1; }
echo "test_route_filler: PASS"

out2=$("$UCODE_BIN" -L "$LIB" -e '
  let filler = require("builder._filler");
  let action = require("builder._shared.route_action");
  let d = { kind:"route_rule", sing_box_type:"",
            fields:[ ...action.fields() ] };
  // sniff
  let o = filler.build(d, { [".name"]:"a1", action:"sniff", sniffer:["tls","http"], timeout:"500ms" });
  let ok = (o.action === "sniff" && o.sniffer[0] === "tls" && o.timeout === "500ms" && o.outbound == null);
  // reject
  let o2 = filler.build(d, { [".name"]:"a2", action:"reject", method:"drop" });
  ok = ok && (o2.action === "reject" && o2.method === "drop");
  // resolve
  let o3 = filler.build(d, { [".name"]:"a3", action:"resolve", server:"dns1", strategy:"prefer_ipv4" });
  ok = ok && (o3.action === "resolve" && o3.server === "dns1" && o3.strategy === "prefer_ipv4");
  // route-options override shared with route
  let o4 = filler.build(d, { [".name"]:"a4", action:"route-options", override_port:"443" });
  ok = ok && (o4.action === "route-options" && o4.override_port === 443);
  print(ok ? "OK\n" : sprintf("BAD %J %J %J %J\n", o, o2, o3, o4));
')
echo "$out2"
echo "$out2" | grep -q '^OK$' || { echo "FAIL action"; exit 1; }
echo "test_route_filler(action): PASS"
