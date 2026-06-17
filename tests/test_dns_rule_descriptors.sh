#!/bin/sh
set -eu
. "$(dirname "$0")/lib/sb_helpers.sh"
LIB="${SB_LIB}"
UCODE="${UCODE_BIN:-ucode}"
command -v "$UCODE" >/dev/null 2>&1 || { echo "SKIP: no ucode"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/t.uc" <<'UC'
require("builder.dns_rule.registry");
let reg = require("builder.protocols.registry");
let filler = require("builder._filler");
let headless = require("builder.dns_rule.headless");
let d = reg.get("dns_rule", "default");
if (d == null) { print("FAIL: default not registered\n"); exit(1); }
let r = filler.build(d, { [".name"]: "r1", domain_suffix: [".cn"], action: "route", server: "dns1" });
if (r.domain_suffix[0] != ".cn" || r.server != "dns1" || r.action != "route") { print(sprintf("FAIL default %J\n", r)); exit(1); }
if ("type" in r || "tag" in r) { print(sprintf("FAIL: default emitted header %J\n", r)); exit(1); }
let l = reg.get("dns_rule", "logical");
if (l == null) { print("FAIL: logical not registered\n"); exit(1); }
// `rules` is UI-only (no json_key) — must NOT appear in filler output; mode does.
let lo = filler.build(l, { [".name"]: "lg", mode: "and", rules: ["a","b"], action: "route", server: "dns1" });
if (lo.mode != "and") { print(sprintf("FAIL logical mode %J\n", lo)); exit(1); }
if ("rules" in lo) { print("FAIL: logical rules leaked to JSON (must be UI-only)\n"); exit(1); }
// headless drops action + top-level-only matchers (rule_set/clash_mode/inbound).
let h = headless.build({ [".name"]: "sub", domain_keyword: ["ads"], action: "route", server: "x", clash_mode: "rule", rule_set: ["rs"] });
if ("action" in h || "server" in h || "clash_mode" in h || "rule_set" in h) { print(sprintf("FAIL headless leak %J\n", h)); exit(1); }
if (h.domain_keyword[0] != "ads") { print(sprintf("FAIL headless matcher %J\n", h)); exit(1); }
print("OK\n");
UC
out="$("$UCODE" -L "$LIB" "$WORK/t.uc" 2>&1)"
echo "$out" | grep -q OK || { echo "FAIL: $out"; exit 1; }
echo "PASS"
