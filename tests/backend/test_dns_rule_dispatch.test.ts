import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

describe("test_dns_rule_dispatch", () => {
  useGuest();

  it("dns.build_rules: logical inline, dangling server drop, referenced rulesets", async () => {
    const src = `
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
  if (r.type == "logical") { has_logical = true; if (!length(r.rules)) { print("FAIL: logical empty\\n"); exit(1); } }
  if (r.domain_keyword && r.domain_keyword[0] == "ads" && r.type != "logical") consumed_sub_toplevel++;
  if (r.server == "missing") has_bad = true;
  if (r.domain_suffix && r.domain_suffix[0] == ".cn" && r.rule_set && r.rule_set[0] == "rs1") r1ok = true;
}
if (!has_logical) { print("FAIL: no logical rule\\n"); exit(1); }
if (consumed_sub_toplevel != 0) { print("FAIL: consumed sub-rule emitted top-level\\n"); exit(1); }
if (has_bad) { print("FAIL: dangling server rule not dropped\\n"); exit(1); }
if (!r1ok) { print("FAIL: r1 rule_set not resolved\\n"); exit(1); }
let refs = dns.referenced_rulesets(cur);
if (refs[0] != "rs1" || length(refs) != 1) { print(sprintf("FAIL refs %J\\n", refs)); exit(1); }
print("OK\\n");
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("OK");
  });
});
