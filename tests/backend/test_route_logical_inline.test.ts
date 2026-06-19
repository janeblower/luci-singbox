import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

// Port of tests/backend/test_route_logical_inline.sh
// A logical rule inlines its referenced default rules as headless (action
// stripped, no rule_set/inbound), the consumed default rule is NOT emitted
// top-level, and logical carries type+mode.
describe("route logical inline (headless inlining)", () => {
  useGuest();

  it("logical rule inlines child as headless; child not emitted top-level; logical has type+mode", async () => {
    const src = `
      let uci=require("uci"), fs=require("fs"), route=require("route");
      let dir="/tmp/logic_test"; fs.mkdir(dir);
      let q=chr(39);
      let cfg = join("\\n", [
        sprintf("config route_rule %schild%s", q, q),
        sprintf("\\toption enabled %s1%s", q, q), sprintf("\\toption type %sdefault%s", q, q),
        sprintf("\\toption action %sroute%s", q, q), sprintf("\\toption outbound %sproxy%s", q, q),
        sprintf("\\tlist domain_suffix %sa.com%s", q, q), sprintf("\\tlist inbound %smixed-in%s", q, q),
        sprintf("config route_rule %slg%s", q, q),
        sprintf("\\toption enabled %s1%s", q, q), sprintf("\\toption type %slogical%s", q, q),
        sprintf("\\toption mode %sand%s", q, q), sprintf("\\toption action %sreject%s", q, q),
        sprintf("\\tlist rules %schild%s", q, q),
        sprintf("config outbound %sproxy%s", q, q), sprintf("\\toption type %svless%s", q, q),
      ]) + "\\n";
      let f=fs.open(sprintf("%s/singbox-ui",dir),"w"); f.write(cfg); f.close();
      let r = route.build_route_rules(uci.cursor(dir), null);
      let ok = (length(r.rules) == 1);
      let lg = r.rules[0];
      ok = ok && (lg.type == "logical" && lg.mode == "and" && lg.action == "reject");
      ok = ok && (length(lg.rules) == 1);
      let h = lg.rules[0];
      ok = ok && (h.domain_suffix[0] == "a.com" && h.action == null && h.inbound == null && h.outbound == null);
      print(ok ? "OK\\n" : sprintf("BAD %J\\n", r.rules));
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("OK");
  });
});
