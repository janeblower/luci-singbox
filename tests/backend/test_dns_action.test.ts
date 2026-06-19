import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

// Port of tests/backend/test_dns_action.sh
// Verifies builder._shared.dns_action fields(): action-gated emit of
// route/reject/predefined/route-options actions and default_when_empty fallback.
describe("dns_action shared block", () => {
  useGuest();

  it("routes to server with rewrite_ttl coerced to int; rejects foreign fields", async () => {
    const src = `
      let reg = require("builder.protocols.registry");
      let filler = require("builder._filler");
      let act = require("builder._shared.dns_action");
      reg.register({ kind: "dns_rule", type: "ta", sing_box_type: "", fields: act.fields() });
      let d = reg.get("dns_rule", "ta");
      // route: server + rewrite_ttl emitted; reject/predefined fields suppressed.
      let r1 = filler.build(d, { [".name"]: "r1", action: "route", server: "dns1", rewrite_ttl: "60" });
      if (r1.action != "route" || r1.server != "dns1" || r1.rewrite_ttl != 60) { print(sprintf("FAIL route %J\\n", r1)); exit(1); }
      if ("method" in r1 || "rcode" in r1) { print(sprintf("FAIL: foreign fields in route %J\\n", r1)); exit(1); }
      print("OK\\n");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("OK");
  });

  it("reject emits method; suppresses server field", async () => {
    const src = `
      let reg = require("builder.protocols.registry");
      let filler = require("builder._filler");
      let act = require("builder._shared.dns_action");
      reg.register({ kind: "dns_rule", type: "ta2", sing_box_type: "", fields: act.fields() });
      let d = reg.get("dns_rule", "ta2");
      let r2 = filler.build(d, { [".name"]: "r2", action: "reject", method: "drop" });
      if (r2.action != "reject" || r2.method != "drop") { print(sprintf("FAIL reject %J\\n", r2)); exit(1); }
      if ("server" in r2) { print("FAIL: route field in reject\\n"); exit(1); }
      print("OK\\n");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("OK");
  });

  it("predefined emits rcode + answer list", async () => {
    const src = `
      let reg = require("builder.protocols.registry");
      let filler = require("builder._filler");
      let act = require("builder._shared.dns_action");
      reg.register({ kind: "dns_rule", type: "ta3", sing_box_type: "", fields: act.fields() });
      let d = reg.get("dns_rule", "ta3");
      let r3 = filler.build(d, { [".name"]: "r3", action: "predefined", rcode: "NXDOMAIN", answer: ["a","b"] });
      if (r3.action != "predefined" || r3.rcode != "NXDOMAIN" || length(r3.answer) != 2) { print(sprintf("FAIL predefined %J\\n", r3)); exit(1); }
      print("OK\\n");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("OK");
  });

  it("route-options emits disable_cache bool; suppresses server", async () => {
    const src = `
      let reg = require("builder.protocols.registry");
      let filler = require("builder._filler");
      let act = require("builder._shared.dns_action");
      reg.register({ kind: "dns_rule", type: "ta4", sing_box_type: "", fields: act.fields() });
      let d = reg.get("dns_rule", "ta4");
      let r4 = filler.build(d, { [".name"]: "r4", action: "route-options", disable_cache: "1" });
      if (r4.action != "route-options" || r4.disable_cache != true) { print(sprintf("FAIL route-options %J\\n", r4)); exit(1); }
      if ("server" in r4) { print("FAIL: server in route-options\\n"); exit(1); }
      print("OK\\n");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("OK");
  });

  it("blank action falls back to 'route' via default_when_empty", async () => {
    const src = `
      let reg = require("builder.protocols.registry");
      let filler = require("builder._filler");
      let act = require("builder._shared.dns_action");
      reg.register({ kind: "dns_rule", type: "ta5", sing_box_type: "", fields: act.fields() });
      let d = reg.get("dns_rule", "ta5");
      let r5 = filler.build(d, { [".name"]: "r5", action: "", server: "dns1" });
      if (r5.action != "route") { print(sprintf("FAIL default action %J\\n", r5)); exit(1); }
      print("OK\\n");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("OK");
  });
});
