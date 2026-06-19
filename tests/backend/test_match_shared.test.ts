import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

// Port of tests/backend/test_match_shared.sh
// match.fields(ctx) returns clean field copies and excludes
// rule_set/inbound/auth_user/clash_mode from the headless context.
describe("match shared block (fields by context)", () => {
  useGuest();

  it("route ctx includes domain_suffix/ip_cidr/port and headless-excluded fields; headless excludes rule_set/inbound/auth_user/clash_mode; no _ctx leakage", async () => {
    const src = `
      let match = require("builder._shared.match");
      function names(a){ let o={}; for (let f in a) o[f.name]=1; return o; }
      let r = names(match.fields("route"));
      let h = names(match.fields("headless"));
      let ok = true;
      for (let n in ["domain_suffix","ip_cidr","port"]) ok = ok && r[n] && h[n];
      for (let n in ["rule_set","inbound","auth_user","clash_mode"]) ok = ok && r[n] && !h[n];
      let leaked = false;
      for (let f in match.fields("route")) if ("_ctx" in f) leaked = true;
      ok = ok && !leaked;
      print(ok ? "OK\\n" : "BAD\\n");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("OK");
  });
});
