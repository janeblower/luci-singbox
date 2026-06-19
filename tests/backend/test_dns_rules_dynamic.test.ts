import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

// Port of tests/backend/test_dns_rules_dynamic.sh
// Verifies that the registry accepts dynamic:"dns_rules" as a known dynamic source
// without throwing an error.
describe("dns_rules dynamic source in registry", () => {
  useGuest();

  it("registers a dns_rule field with dynamic:dns_rules without error", async () => {
    const src = `
      let reg = require("builder.protocols.registry");
      reg.register({ kind: "dns_rule", type: "tdyn", sing_box_type: "",
        fields: [ { name: "rules", type: "list", tab: "match", dynamic: "dns_rules", ui_label: "Sub" } ] });
      print("OK\\n");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("OK");
  });
});
