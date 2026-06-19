import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

// Port of tests/backend/test_route_default_config.sh
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

      const VALID = { route:1, "route-options":1, reject:1, "hijack-dns":1, sniff:1, resolve:1 };
      let ok = (length(r.rules) > 0);

      // Every emitted rule must carry a valid sing-box action.
      for (let rule in r.rules) {
        if (!VALID[rule.action]) { print(sprintf("BAD action %J\\n", rule)); ok = false; }
      }

      // The shipped defaults_direct rule -> action route, outbound direct_wan,
      // rule_set [russia_inside, discord].
      let found = null;
      for (let rule in r.rules) if (rule.outbound === "direct_wan" && rule.action === "route") found = rule;
      ok = ok && (found != null);
      ok = ok && (found != null && type(found.rule_set) === "array" && length(found.rule_set) === 2);

      // route_default -> final direct_wan.
      ok = ok && (r.final === "direct_wan");

      // referenced must include both shipped rulesets; build_rule_sets must emit them.
      let refset = {}; for (let n in r.referenced) refset[n] = true;
      ok = ok && refset["russia_inside"] && refset["discord"];
      let sets = ruleset.build_rule_sets(cur, r.referenced);
      let tags = {}; for (let e in sets) tags[e.tag] = true;
      ok = ok && tags["russia_inside"] && tags["discord"];

      print(ok ? "OK\\n" : sprintf("FAILED rules=%J final=%J referenced=%J\\n", r.rules, r.final, r.referenced));
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("OK");
  });
});
