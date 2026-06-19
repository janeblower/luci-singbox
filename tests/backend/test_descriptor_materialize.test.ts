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
  // Real API: mat.tabs = array of tab-name strings, mat.fields = flat array of all fields.
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

    // mat.tabs is an array of tab name strings; mat.fields is a flat array of all fields.
    expect(mat.tabs).toBeDefined();
    expect(Array.isArray(mat.tabs)).toBe(true);
    const tabNames = mat.tabs as string[];
    expect(tabNames).toContain("basic");
    expect(tabNames).toContain("advanced");

    expect(mat.fields).toBeDefined();
    expect(Array.isArray(mat.fields)).toBe(true);
    const fields = mat.fields as Array<{ name: string; tab: string }>;

    // basic tab fields must include server and server_port
    const basicFields = fields.filter((f) => f.tab === "basic");
    const basicNames = basicFields.map((f) => f.name);
    expect(basicNames).toContain("server");
    expect(basicNames).toContain("server_port");

    // advanced tab fields must include myfield
    const advFields = fields.filter((f) => f.tab === "advanced");
    const advNames = advFields.map((f) => f.name);
    expect(advNames).toContain("myfield");

    // dial shared block contributes fields (e.g. detour)
    const allNames = fields.map((f) => f.name);
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
  // mat.tabs is array of strings; mat.fields is flat array — filter by f.tab.
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

    // mat.fields is a flat array of all fields with a .tab property
    expect(mat.fields).toBeDefined();
    expect(Array.isArray(mat.fields)).toBe(true);
    const fields = mat.fields as Array<{ name: string; tab: string }>;

    // advanced tab fields must include adv_opt and _show_advanced toggle
    const advFields = fields.filter((f) => f.tab === "advanced");
    expect(advFields.length).toBeGreaterThan(0);
    const toggleNames = advFields.map((f) => f.name);
    const hasToggle = toggleNames.some((n) => n.startsWith("_show_advanced_"));
    expect(hasToggle).toBe(true);
    // Toggle must be FIRST among advanced-tab fields
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
      // mat.fields is a flat array of all fields
      let found_toggle = false;
      for (let f in mat.fields) {
        if (f.name && index(f.name, "_show_advanced_") === 0) {
          found_toggle = true;
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
