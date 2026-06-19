import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

// Port of tests/backend/test_advanced_scope.sh
// Guards Bug 4: no _show_advanced_* toggle for inbound/outbound; kept for
// dns/route_rule.
describe("advanced_scope (no advanced toggles for in/out; kept for dns/route)", () => {
  useGuest();

  async function probe(kind: string, type: string): Promise<string> {
    const r = await runUcode(
      `
require("outbound"); require("inbound");
let d = require("builder.protocols.schema_dump");
let s = d.dump_all();
let m = s[ARGV[0]] ? s[ARGV[0]][ARGV[1]] : null;
if (!m) { print("nomat"); return; }
let has = false;
for (let f in m.fields)
  if (index(f.name, "_show_advanced_") === 0) has = true;
print(has ? "toggle" : "none");
`,
      [kind, type],
    );
    if (r.exitCode !== 0)
      throw new Error(`probe(${kind},${type}) failed: ${r.stderr}`);
    return r.stdout.trim();
  }

  it("outbound (hysteria2) has NO advanced toggle", async () => {
    expect(await probe("outbound", "hysteria2")).toBe("none");
  });

  it("inbound (tproxy) has NO advanced toggle", async () => {
    expect(await probe("inbound", "tproxy")).toBe("none");
  });

  it("route_rule (default) HAS advanced toggle", async () => {
    expect(await probe("route_rule", "default")).toBe("toggle");
  });
});
