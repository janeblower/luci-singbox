#!/bin/sh
set -eu
. "$(dirname "$0")/../lib/sb_helpers.sh"
LIB="${SB_LIB}"
UCODE="${UCODE_BIN:-ucode}"
command -v "$UCODE" >/dev/null 2>&1 || { echo "SKIP: no ucode"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/t.uc" <<'UC'
let reg = require("builder.protocols.registry");
let filler = require("builder._filler");
for (let k in [ "cache", "clash_api", "dns_rule" ])
  reg.register({ kind: k, type: "h_"+k, sing_box_type: k,
    fields: [ { name: "v", type: "string", tab: "basic", json_key: "v" } ] });
for (let k in [ "cache", "clash_api", "dns_rule" ]) {
  let out = filler.build(reg.get(k, "h_"+k), { [".name"]: "sec", v: "val" });
  if ("type" in out || "tag" in out) { print(sprintf("FAIL %s has header\n", k)); exit(1); }
  if (out.v != "val") { print(sprintf("FAIL %s missing v\n", k)); exit(1); }
}
print("OK\n");
UC
out="$("$UCODE" -L "$LIB" "$WORK/t.uc" 2>&1)"
echo "$out" | grep -q "OK" || { echo "FAIL: $out"; exit 1; }
echo "PASS"
