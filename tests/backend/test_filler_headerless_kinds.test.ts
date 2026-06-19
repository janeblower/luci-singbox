import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

// Port of tests/backend/test_filler_headerless_kinds.sh
describe("filler_headerless_kinds (filler.build for cache/clash_api/dns_rule have no type/tag)", () => {
  useGuest();

  it("headerless kinds: cache, clash_api, dns_rule have no type/tag in output", async () => {
    const r = await runUcode(`
let reg = require("builder.protocols.registry");
let filler = require("builder._filler");
for (let k in [ "cache", "clash_api", "dns_rule" ])
  reg.register({ kind: k, type: "h_"+k, sing_box_type: k,
    fields: [ { name: "v", type: "string", tab: "basic", json_key: "v" } ] });
for (let k in [ "cache", "clash_api", "dns_rule" ]) {
  let out = filler.build(reg.get(k, "h_"+k), { [".name"]: "sec", v: "val" });
  if ("type" in out || "tag" in out) { print(sprintf("FAIL %s has header\\n", k)); exit(1); }
  if (out.v != "val") { print(sprintf("FAIL %s missing v\\n", k)); exit(1); }
}
print("OK\\n");
`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("OK");
  });
});
