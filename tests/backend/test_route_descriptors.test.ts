import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

// Port of tests/backend/test_route_descriptors.sh
// Registry accepts route_rule/rule_set kinds and the new dynamic sources;
// descriptors register and materialize; headless strips excluded fields.
describe("route descriptors (registry + materialize + headless)", () => {
  useGuest();

  it("registry accepts route_rule and rule_set kinds; materialize returns kind metadata", async () => {
    const src = `
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
      print((m != null && m.kind === "route_rule") ? "OK\\n" : "BAD\\n");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("OK");
  });

  it("builder.route.registry eager-loads all 5 real descriptors with expected fields", async () => {
    const src = `
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
      print(ok ? "OK2\\n" : "BAD2\\n");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("OK2");
  });

  it("headless.build strips rule_set/inbound/type/tag but keeps domain_suffix", async () => {
    const src = `
      let h = require("builder.route.headless");
      let obj = h.build({ [".name"]:"x", domain_suffix: ["example.com"], rule_set: ["my_rs"], inbound: ["tun0"] });
      let ok = (obj["domain_suffix"] != null) && (obj["rule_set"] == null) &&
               (obj["inbound"] == null) && (obj["type"] == null) && (obj["tag"] == null);
      print(ok ? "OK3\\n" : sprintf("BAD3 %J\\n", obj));
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("OK3");
  });
});
