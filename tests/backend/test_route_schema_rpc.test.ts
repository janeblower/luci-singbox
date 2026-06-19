import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

// Port of tests/backend/test_route_schema_rpc.sh
// dump_all() projects route_rule + rule_set with frontend-safe fields
// (depends/values/dynamic/advanced/min_version present;
// backend-only json_key/requires/coerce absent).
describe("route schema RPC (dump_all projection)", () => {
  useGuest();

  it("dump_all() has route_rule and rule_set keys with expected subtypes and field gates", async () => {
    const src = `
      let dump = require("builder.protocols.schema_dump").dump_all();
      let ok = (dump.route_rule != null && dump.rule_set != null);
      ok = ok && dump.route_rule.default != null && dump.route_rule.logical != null;
      ok = ok && dump.rule_set.remote != null && dump.rule_set.inline != null;
      let pf = null;
      for (let f in dump.route_rule.default.fields) if (f.name == "package_name_regex") pf = f;
      ok = ok && (pf != null && pf.min_version == "1.14" && pf.json_key == null && pf.coerce == null);
      let of = null;
      for (let f in dump.route_rule.default.fields) if (f.name == "outbound") of = f;
      ok = ok && (of != null && of.depends != null && of.requires == null && of.dynamic == "outbounds");
      print(ok ? "OK\\n" : "BAD\\n");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("OK");
  });
});
