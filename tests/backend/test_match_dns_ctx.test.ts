import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

// Port of tests/backend/test_match_dns_ctx.sh
// Verifies builder._shared.match.fields() returns correct sets for dns /
// dns_headless / route contexts: DNS-only matchers, exclusions from headless,
// route-only matchers, and per-field version gates.
describe("match DNS context (builder._shared.match)", () => {
  useGuest();

  it("DNS-only matchers present in dns context", async () => {
    const src = `
      let match = require("builder._shared.match");
      function names(ctx) { let m = {}; for (let f in match.fields(ctx)) m[f.name] = f; return m; }
      let dns = names("dns");
      let missing = [];
      for (let n in ["query_type","ip_accept_any","match_response","response_rcode",
                     "response_answer","interface_address","preferred_by"])
        if (!(n in dns)) push(missing, n);
      if (length(missing)) { print("MISSING:" + join(",", missing) + "\\n"); exit(1); }
      print("OK\\n");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("OK");
  });

  it("common matchers (domain_suffix/ip_cidr/network/protocol/rule_set/clash_mode) present in dns context", async () => {
    const src = `
      let match = require("builder._shared.match");
      function names(ctx) { let m = {}; for (let f in match.fields(ctx)) m[f.name] = f; return m; }
      let dns = names("dns");
      let missing = [];
      for (let n in ["domain_suffix","ip_cidr","network","protocol","rule_set","clash_mode"])
        if (!(n in dns)) push(missing, n);
      if (length(missing)) { print("MISSING:" + join(",", missing) + "\\n"); exit(1); }
      print("OK\\n");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("OK");
  });

  it("rule_set/inbound/auth_user/clash_mode/rule_set_ip_cidr_match_source absent from dns_headless", async () => {
    const src = `
      let match = require("builder._shared.match");
      function names(ctx) { let m = {}; for (let f in match.fields(ctx)) m[f.name] = f; return m; }
      let dnsh = names("dns_headless");
      let present = [];
      for (let n in ["rule_set","inbound","auth_user","clash_mode","rule_set_ip_cidr_match_source"])
        if (n in dnsh) push(present, n);
      if (length(present)) { print("PRESENT:" + join(",", present) + "\\n"); exit(1); }
      if (!("domain_suffix" in dnsh)) { print("FAIL: dns_headless missing domain_suffix\\n"); exit(1); }
      print("OK\\n");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("OK");
  });

  it("client is route-only: absent from dns, present in route", async () => {
    const src = `
      let match = require("builder._shared.match");
      function names(ctx) { let m = {}; for (let f in match.fields(ctx)) m[f.name] = f; return m; }
      let dns = names("dns");
      let route = names("route");
      if ("client" in dns) { print("FAIL: dns has route-only client\\n"); exit(1); }
      if (!("client" in route)) { print("FAIL: route lost client\\n"); exit(1); }
      print("OK\\n");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("OK");
  });

  it("version gates: match_response=1.14, interface_address=1.13, rule_set_ip_cidr_accept_empty max=1.16", async () => {
    const src = `
      let match = require("builder._shared.match");
      function names(ctx) { let m = {}; for (let f in match.fields(ctx)) m[f.name] = f; return m; }
      let dns = names("dns");
      if (dns.match_response.min_version != "1.14") { print("FAIL: match_response min_version\\n"); exit(1); }
      if (dns.interface_address.min_version != "1.13") { print("FAIL: interface_address min_version\\n"); exit(1); }
      if (dns.rule_set_ip_cidr_accept_empty == null || dns.rule_set_ip_cidr_accept_empty.max_version != "1.16")
        { print("FAIL: accept_empty max_version\\n"); exit(1); }
      print("OK\\n");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("OK");
  });

  it("route context still has domain_suffix unchanged", async () => {
    const src = `
      let match = require("builder._shared.match");
      function names(ctx) { let m = {}; for (let f in match.fields(ctx)) m[f.name] = f; return m; }
      let route = names("route");
      if (!("domain_suffix" in route)) { print("FAIL: route missing domain_suffix\\n"); exit(1); }
      print("OK\\n");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("OK");
  });
});
