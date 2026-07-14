import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

// Guard the SHIPPED default UCI config (etc/config/singbox-ui): it must carry NO
// routing opinion at all — no outbound, no route_rule, no route_default, no
// dns_rule.
//
// It used to ship some, and they were wrong in the direction that silently does
// nothing: `defaults_direct` sent `russia_inside` straight out the WAN. But
// russia_inside is not "Russian domains, send them direct" — it is itdoginfo's
// list of what is BLOCKED for a user inside Russia (a superset of anime, block,
// geoblock, news, porn, hdrezka, meta, tiktok, twitter, youtube, discord). Those
// are precisely the domains that need a proxy, and the seed routed them around it.
//
// A correct default cannot be shipped either: it would have to point at a proxy,
// and a fresh install has none — route.uc drops an action=route rule with no
// outbound. So the box comes up with the 25 built-in rule-sets ready and no
// opinion about how to use them.
//
// This guard exists so nobody quietly re-adds a broken default. If a real one is
// ever designed, this test is where the intent gets written down.
describe("route default config guard (shipped singbox-ui config)", () => {
  useGuest();

  it("ships no outbound, no route rules and no default route", async () => {
    const cfgPath = "/tmp/work/singbox-ui/root/etc/config/singbox-ui";
    const src = `
      let uci = require("uci");
      let fs  = require("fs");
      let route = require("route");

      let dir = "/tmp/route_default_cfg";
      fs.mkdir(dir);
      let src = fs.open("${cfgPath}", "r");
      let body = src.read("all"); src.close();
      let dst = fs.open(sprintf("%s/singbox-ui", dir), "w");
      dst.write(body); dst.close();

      let cur = uci.cursor(dir);

      // Count the sections that would express a routing opinion.
      let counts = { outbound: 0, route_rule: 0, route_default: 0, dns_rule: 0, ruleset: 0 };
      for (let kind in keys(counts))
        cur.foreach("singbox-ui", kind, function(_s) { counts[kind]++; });

      // route.uc over the shipped config: the only rules it may produce are the
      // hijack-dns ones DERIVED from the inbounds (tproxy hijack_dns + the direct
      // DNS listener). No final, and nothing referencing a rule-set.
      let r = route.build_route_rules(cur, null);
      let actions = [];
      for (let rule in (r.rules ?? [])) push(actions, rule.action);

      // F1 regression: a tun inbound's auto_route is a routing opinion too — it
      // just lives one subsystem over from route_rule/route_default (it is
      // helpers.transparent_conflict / generate.uc's ownership guard, not
      // route.uc). The seed used to pre-arm it on the disabled tun_in, which
      // this guard's own foreach loop above could not see (it only counts
      // outbound/route_rule/route_default/dns_rule/ruleset). Check it directly.
      let tun_auto_route = [];
      cur.foreach("singbox-ui", "inbound", function(s) {
        if (s.protocol === "tun" && s.auto_route === "1") push(tun_auto_route, s[".name"]);
      });

      print(sprintf("%J\\n", {
        counts: counts,
        actions: actions,
        final: r.final,
        referenced: r.referenced,
        tun_auto_route: tun_auto_route,
      }));
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);

    const got = JSON.parse(r.stdout) as {
      counts: Record<string, number>;
      actions: string[];
      final: string | null;
      referenced: string[];
      tun_auto_route: string[];
    };

    // No routing opinion whatsoever.
    expect(got.counts.outbound).toBe(0);
    expect(got.counts.route_rule).toBe(0);
    expect(got.counts.route_default).toBe(0);
    expect(got.counts.dns_rule).toBe(0);
    // The rule-sets are created by uci-defaults/92-*, not by the config file, so
    // there is exactly one source of truth for them.
    expect(got.counts.ruleset).toBe(0);

    // The only rules are the ones derived from the inbounds themselves.
    expect(got.actions).toEqual(["hijack-dns", "hijack-dns"]);
    expect(got.final).toBeNull();
    expect(got.referenced).toEqual([]);

    // No inbound pre-arms auto_route either (F1): that is a routing opinion
    // one subsystem over, and the seed has no more business shipping it on a
    // tun than it does a route_default.
    expect(got.tun_auto_route).toEqual([]);
  });
});
