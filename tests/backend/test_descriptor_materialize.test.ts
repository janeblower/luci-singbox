import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode, runUcodeJSON } from "../helpers/ucode.ts";

// Port of tests/backend/test_descriptor_materialize.sh
// Validates registry.materialize(kind, type):
//   - field union (protocol + shared blocks gated by flags)
//   - per-tab _show_advanced_<tab> injection for dns/route kinds
//   - rejection of malformed descriptors (missing tab, unknown shared key)
//
// NOTE: _show_advanced_<tab> injection is now scoped to dns/route kinds only
// (inbound/outbound show all fields, Bug 4), so injection tests register
// under kind "dns". The outbound "no toggle" side is covered by
// tests/test_advanced_scope.sh.

describe("descriptor materialize", () => {
  useGuest();

  // Test 1: register + materialize on a minimal descriptor with one shared block.
  it("Test 1: materialize merges protocol fields + shared block fields", async () => {
    const src = `
      let reg = require("builder.protocols.registry");
      // Register a minimal outbound descriptor referencing 'dial' shared block.
      reg.register({
        kind: "outbound", type: "mat_test1", sing_box_type: "mat_test1",
        shared: { dial: {} },
        fields: [
          { name: "server",      type: "string", tab: "basic",    json_key: "server" },
          { name: "server_port", type: "number", tab: "basic",    json_key: "server_port" },
          { name: "myfield",     type: "string", tab: "advanced", json_key: "myfield", advanced: true },
        ],
      });
      let mat = reg.materialize("outbound", "mat_test1");
      print(sprintf("%J", mat));
    `;
    const mat = await runUcodeJSON<Record<string, unknown>>(src);

    // Tabs object must exist
    expect(mat.tabs).toBeDefined();
    const tabs = mat.tabs as Record<string, unknown[]>;

    // basic tab must contain server and server_port
    const basicFields = tabs.basic as Array<{ name: string }>;
    expect(basicFields).toBeDefined();
    const basicNames = basicFields.map((f) => f.name);
    expect(basicNames).toContain("server");
    expect(basicNames).toContain("server_port");

    // advanced tab must contain myfield
    const advFields = tabs.advanced as Array<{ name: string }>;
    expect(advFields).toBeDefined();
    const advNames = advFields.map((f) => f.name);
    expect(advNames).toContain("myfield");

    // dial shared block contributes fields (e.g. detour, bind_interface, routing_mark)
    // at least detour must appear in some tab
    const allFields = Object.values(tabs).flat() as Array<{ name: string }>;
    const allNames = allFields.map((f) => f.name);
    expect(allNames).toContain("detour");
  });

  // Test 2: descriptor with missing tab on a field is rejected.
  it("Test 2: descriptor with missing tab on a field is rejected", async () => {
    const src = `
      let reg = require("builder.protocols.registry");
      let threw = false;
      try {
        reg.register({
          kind: "outbound", type: "mat_test2_bad", sing_box_type: "x",
          fields: [
            { name: "f1", type: "string", json_key: "f1" },
          ],
        });
      } catch (e) { threw = true; }
      print(threw ? "THREW" : "NOTHREW");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("THREW");
  });

  // Test 3: unknown shared key rejected.
  it("Test 3: unknown shared key rejected", async () => {
    const src = `
      let reg = require("builder.protocols.registry");
      let threw = false;
      try {
        reg.register({
          kind: "outbound", type: "mat_test3_bad", sing_box_type: "x",
          shared: { nonexistent_shared_block: {} },
          fields: [
            { name: "f1", type: "string", tab: "basic", json_key: "f1" },
          ],
        });
      } catch (e) { threw = true; }
      print(threw ? "THREW" : "NOTHREW");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("THREW");
  });

  // Test 4: _show_advanced_<tab> auto-injected and prepended first (dns kind only).
  it("Test 4: _show_advanced_<tab> auto-injected for dns kind", async () => {
    const src = `
      let reg = require("builder.protocols.registry");
      reg.register({
        kind: "dns", type: "mat_test4", sing_box_type: "mat_test4",
        fields: [
          { name: "server",  type: "string", tab: "basic", json_key: "server" },
          { name: "adv_opt", type: "string", tab: "advanced", json_key: "adv_opt", advanced: true },
        ],
      });
      let mat = reg.materialize("dns", "mat_test4");
      print(sprintf("%J", mat));
    `;
    const mat = await runUcodeJSON<Record<string, unknown>>(src);
    const tabs = mat.tabs as Record<string, Array<{ name: string }>>;

    // advanced tab must start with _show_advanced_advanced toggle
    const advFields = tabs.advanced;
    expect(advFields).toBeDefined();
    expect(advFields.length).toBeGreaterThan(0);
    // The _show_advanced toggle must be present in the advanced tab
    const toggleNames = advFields.map((f) => f.name);
    const hasToggle = toggleNames.some((n) => n.startsWith("_show_advanced_"));
    expect(hasToggle).toBe(true);
    // Toggle must be FIRST
    expect(advFields[0].name).toMatch(/^_show_advanced_/);
  });

  // Additional: outbound kind must NOT have _show_advanced toggle
  it("outbound kind does NOT get _show_advanced_<tab> toggle", async () => {
    const src = `
      let reg = require("builder.protocols.registry");
      reg.register({
        kind: "outbound", type: "mat_out_noadv", sing_box_type: "x",
        fields: [
          { name: "server",  type: "string", tab: "basic",    json_key: "server" },
          { name: "adv_opt", type: "string", tab: "advanced", json_key: "adv_opt", advanced: true },
        ],
      });
      let mat = reg.materialize("outbound", "mat_out_noadv");
      let tabs = mat.tabs;
      let found_toggle = false;
      for (let tab, fields in tabs) {
        if (type(fields) !== "array") continue;
        for (let f in fields) {
          if (f.name && index(f.name, "_show_advanced_") === 0) {
            found_toggle = true;
          }
        }
      }
      print(found_toggle ? "HAS_TOGGLE" : "NO_TOGGLE");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("NO_TOGGLE");
  });

  // materialize returns null for an unregistered type
  it("materialize returns null for unknown type", async () => {
    const src = `
      let reg = require("builder.protocols.registry");
      let mat = reg.materialize("outbound", "nonexistent_xyz_protocol");
      print(mat == null ? "NULL" : "NOT_NULL");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("NULL");
  });
});
