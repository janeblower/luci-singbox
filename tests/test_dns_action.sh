#!/bin/sh
set -eu
. "$(dirname "$0")/lib/sb_helpers.sh"
LIB="${SB_LIB}"
UCODE="${UCODE_BIN:-ucode}"
command -v "$UCODE" >/dev/null 2>&1 || { echo "SKIP: no ucode"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/t.uc" <<'UC'
let reg = require("builder.protocols.registry");
let filler = require("builder._filler");
let act = require("builder._shared.dns_action");
reg.register({ kind: "dns_rule", type: "ta", sing_box_type: "", fields: act.fields() });
let d = reg.get("dns_rule", "ta");
// route: server + rewrite_ttl emitted; reject/predefined fields suppressed.
let r1 = filler.build(d, { [".name"]: "r1", action: "route", server: "dns1", rewrite_ttl: "60" });
if (r1.action != "route" || r1.server != "dns1" || r1.rewrite_ttl != 60) { print(sprintf("FAIL route %J\n", r1)); exit(1); }
if ("method" in r1 || "rcode" in r1) { print(sprintf("FAIL: foreign fields in route %J\n", r1)); exit(1); }
// reject: method emitted, server suppressed.
let r2 = filler.build(d, { [".name"]: "r2", action: "reject", method: "drop" });
if (r2.action != "reject" || r2.method != "drop") { print(sprintf("FAIL reject %J\n", r2)); exit(1); }
if ("server" in r2) { print("FAIL: route field in reject\n"); exit(1); }
// predefined: rcode + answer list.
let r3 = filler.build(d, { [".name"]: "r3", action: "predefined", rcode: "NXDOMAIN", answer: ["a","b"] });
if (r3.action != "predefined" || r3.rcode != "NXDOMAIN" || length(r3.answer) != 2) { print(sprintf("FAIL predefined %J\n", r3)); exit(1); }
// route-options shares disable_cache (no server).
let r4 = filler.build(d, { [".name"]: "r4", action: "route-options", disable_cache: "1" });
if (r4.action != "route-options" || r4.disable_cache != true) { print(sprintf("FAIL route-options %J\n", r4)); exit(1); }
if ("server" in r4) { print("FAIL: server in route-options\n"); exit(1); }
// default_when_empty: blank action → "route".
let r5 = filler.build(d, { [".name"]: "r5", action: "", server: "dns1" });
if (r5.action != "route") { print(sprintf("FAIL default action %J\n", r5)); exit(1); }
print("OK\n");
UC
out="$("$UCODE" -L "$LIB" "$WORK/t.uc" 2>&1)"
echo "$out" | grep -q OK || { echo "FAIL: $out"; exit 1; }
echo "PASS"
