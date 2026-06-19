import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

// Port of tests/backend/test_registry_new_kinds.sh
// New kinds (cache, clash_api, dns_rule) must register without throwing.
// max_version must be accepted and round-trip as a valid 2-part string.

describe("registry: new kinds", () => {
  useGuest();

  it("cache, clash_api, and dns_rule register without throwing", async () => {
    const src = `
      let reg = require("builder.protocols.registry");
      for (let k in [ "cache", "clash_api", "dns_rule" ])
        reg.register({ kind: k, type: k, sing_box_type: k,
          fields: [ { name: "x", type: "string", tab: "basic", json_key: "x" } ] });
      print("OK\\n");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("OK");
  });

  it("max_version is accepted and stored on a field", async () => {
    const src = `
      let reg = require("builder.protocols.registry");
      reg.register({ kind: "cache", type: "c2", sing_box_type: "cache_file",
        fields: [ { name: "y", type: "string", tab: "basic", json_key: "y", max_version: "1.13" } ] });
      let d = reg.get("cache", "c2");
      let f = d.fields[0];
      print(f.max_version ?? "MISSING");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("1.13");
  });
});
