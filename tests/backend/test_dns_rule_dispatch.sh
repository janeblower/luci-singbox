#!/bin/sh
set -eu
. "$(dirname "$0")/../lib/sb_helpers.sh"
LIB="${SB_LIB}"
UCODE="${UCODE_BIN:-ucode}"
command -v "$UCODE" >/dev/null 2>&1 || { echo "SKIP: no ucode"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/t.uc" <<'UC'
let dns = require("dns");
let CFG = {
  dns_server: [ { [".name"]: "dns1", enabled: "1", type: "udp" } ],
  ruleset:    [ { [".name"]: "rs1", enabled: "1" } ],
  dns_rule: [
    { [".name"]: "r1", enabled: "1", type: "default", domain_suffix: [".cn"],
      rule_set: [ "rs1" ], action: "route", server: "dns1" },
    { [".name"]: "rsub", enabled: "1", type: "default", domain_keyword: [ "ads" ],
      action: "route", server: "dns1" },
    { [".name"]: "rlog", enabled: "1", type: "logical", mode: "or",
      rules: [ "rsub" ], action: "route", server: "dns1" },
    { [".name"]: "rbad", enabled: "1", type: "default", domain: [ "x" ],
      action: "route", server: "missing" },
  ],
};
let cur = {
  foreach: function(_p, t, fn) { for (let s in (CFG[t] || [])) fn(s); },
  get_all: function(_p, t) { return CFG[t]; },
};
let rules = dns.build_rules(cur);
let has_logical = false, consumed_sub_toplevel = 0, has_bad = false, r1ok = false;
for (let r in rules) {
  if (r.type == "logical") { has_logical = true; if (!length(r.rules)) { print("FAIL: logical empty\n"); exit(1); } }
  if (r.domain_keyword && r.domain_keyword[0] == "ads" && r.type != "logical") consumed_sub_toplevel++;
  if (r.server == "missing") has_bad = true;
  if (r.domain_suffix && r.domain_suffix[0] == ".cn" && r.rule_set && r.rule_set[0] == "rs1") r1ok = true;
}
if (!has_logical) { print("FAIL: no logical rule\n"); exit(1); }
if (consumed_sub_toplevel != 0) { print("FAIL: consumed sub-rule emitted top-level\n"); exit(1); }
if (has_bad) { print("FAIL: dangling server rule not dropped\n"); exit(1); }
if (!r1ok) { print("FAIL: r1 rule_set not resolved\n"); exit(1); }
let refs = dns.referenced_rulesets(cur);
if (refs[0] != "rs1" || length(refs) != 1) { print(sprintf("FAIL refs %J\n", refs)); exit(1); }
print("OK\n");
UC
out="$("$UCODE" -L "$LIB" "$WORK/t.uc" 2>&1)"
echo "$out" | grep -q OK || { echo "FAIL: $out"; exit 1; }
echo "PASS"
