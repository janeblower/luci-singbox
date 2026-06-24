import { describe, expect, it } from "bun:test";
import { collectOutboundTypes, collectTabs, collectModes } from "./_plugins_harness.ts";

// Pure-function coverage of the contribution-merge helpers. We import the
// extracted pure helpers (no LuCI runtime) — see _plugins_harness.ts which
// re-exports the merge logic from lib/plugins.js via a thin shim.

describe("plugins loader merge helpers", () => {
  const plugins = [
    { name: "a", api: { outboundTypes: () => [["a_type", "A"]], tabs: () => [{ id: "a", label: "A", build: () => ({}) }] } },
    { name: "b", api: { mode: () => ({ id: "easy", label: "Easy", render: () => ({}) }) } },
  ];

  it("collects outbound types from all plugins", () => {
    expect(collectOutboundTypes(plugins)).toEqual([["a_type", "A"]]);
  });
  it("collects tabs", () => {
    expect(collectTabs(plugins).map((t) => t.id)).toEqual(["a"]);
  });
  it("collects modes", () => {
    expect(collectModes(plugins).map((m) => m.id)).toEqual(["easy"]);
  });
  it("mode switcher is suppressed when no plugin provides a mode", () => {
    expect(collectModes([{ name: "x", api: {} }])).toEqual([]);
  });
});
