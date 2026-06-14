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
