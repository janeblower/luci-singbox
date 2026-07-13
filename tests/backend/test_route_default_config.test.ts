import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

// Guard the SHIPPED default UCI config (etc/config/singbox-ui) against the
// route schema. Runs route.uc/ruleset.uc against the real shipped config and
// asserts the emitted route block uses only valid sing-box rule actions and
// resolves its rule-set references.
describe("route default config guard (shipped singbox-ui config)", () => {
  useGuest();

  it("shipped default config produces valid route rules with expected actions, rulesets, and final", async () => {
    // The shipped config is read from the in-tree path on the guest.
    const cfgPath = "/tmp/work/singbox-ui/root/etc/config/singbox-ui";
    const src = `
      let uci = require("uci");
      let fs  = require("fs");
      let route   = require("route");
      let ruleset = require("ruleset");

      // Stage the shipped config as a UCI fixture dir named after the package.
      let dir = "/tmp/route_default_cfg";
      fs.mkdir(dir);
      let src = fs.open("${cfgPath}", "r");
      let body = src.read("all"); src.close();
      let dst = fs.open(sprintf("%s/singbox-ui", dir), "w");
      dst.write(body); dst.close();

      let cur = uci.cursor(dir);
      let r = route.build_route_rules(cur, null);

      const VALID = { route:1, "route-options":1, reject:1, "hijack-dns":1, sniff:1, resolve:1, bypass:1 };
      let ok = (length(r.rules) > 0);

      // Every emitted rule must carry a valid sing-box action.
      for (let rule in r.rules) {
        if (!VALID[rule.action]) { print(sprintf("BAD action %J\\n", rule)); ok = false; }
      }

      // The shipped defaults_direct rule -> action route, outbound wan (the
      // built-in WAN outbound), rule_set [russia_inside, discord].
      let found = null;
      for (let rule in r.rules) if (rule.outbound === "wan" && rule.action === "route") found = rule;
      ok = ok && (found != null);
      ok = ok && (found != null && type(found.rule_set) === "array" && length(found.rule_set) === 2);

      // route_default ships action=bypass -> a TRAILING matcher-less rule carrying
      // the outbound, NOT a final. (final is only a tag; it cannot carry an
      // action.) The guest has no sing-box binary, so helpers.core_at_least()
      // fails open and bypass survives — the degrade-to-route path on an old core
      // is covered by test_route_default_bypass.
      let last = r.rules[length(r.rules) - 1];
      ok = ok && (last != null && last.action === "bypass" && last.outbound === "wan");
      ok = ok && (r.final == null);

      // referenced must include both shipped rulesets; build_rule_sets must emit them.
      let refset = {}; for (let n in r.referenced) refset[n] = true;
      ok = ok && refset["russia_inside"] && refset["discord"];
      let sets = ruleset.build_rule_sets(cur, r.referenced);
      let tags = {}; for (let e in sets) tags[e.tag] = true;
      ok = ok && tags["russia_inside"] && tags["discord"];

      print(ok ? "OK\\n" : sprintf("FAILED rules=%J final=%J referenced=%J\\n", r.rules, r.final, r.referenced));
    `;
    // Pin the core version: the guest installs sing-box from the stock OpenWrt apk
    // feed, which is still 1.12, and route.uc would then degrade the shipped
    // action=bypass to action=route. That degrade is deliberate (1.12 REFUSES a
    // config with an unknown action, so a fresh install would come up dead) and is
    // covered by test_route_default_bypass. Here we want the shipped config's own
    // shape, so we ask for a core that supports it.
    const r = await runUcode(src, [], [], { SINGBOX_CORE_VERSION: "1.13.0" });
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("OK");
  });
});
