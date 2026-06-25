import { describe, expect, it } from "bun:test";
import {
  collectInboundTypes,
  collectModes,
  collectOutboundTypes,
  collectTabs,
  pluginStatusMap,
} from "./_plugins_harness.ts";

// Pure-function coverage of the contribution-merge helpers. We import the
// extracted pure helpers (no LuCI runtime) — see _plugins_harness.ts which
// re-exports the merge logic from lib/plugins.js via a thin shim.

describe("plugins loader merge helpers", () => {
  const plugins = [
    {
      name: "a",
      api: {
        outboundTypes: () => [["a_type", "A"]],
        inboundTypes: () => [["a_in", "A Inbound"]],
        tabs: () => [{ id: "a", label: "A", build: () => ({}) }],
      },
    },
    {
      name: "b",
      api: { mode: () => ({ id: "easy", label: "Easy", render: () => ({}) }) },
    },
  ];

  it("collects outbound types from all plugins", () => {
    expect(collectOutboundTypes(plugins)).toEqual([["a_type", "A"]]);
  });
  it("collects inbound types from all plugins", () => {
    expect(collectInboundTypes(plugins)).toEqual([["a_in", "A Inbound"]]);
  });
  it("returns empty array when no plugin provides inboundTypes", () => {
    expect(collectInboundTypes([{ name: "x", api: {} }])).toEqual([]);
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

describe("plugin install/enable status mapping", () => {
  // Regression: the Plugins tab must treat "installed" (package on disk →
  // present in the raw `plugins` rpcd list) and "enabled" (UCI flag) as
  // independent. The old code derived "installed" from the enabled-only
  // loadEnabled() list, which made the Enable button permanently unreachable
  // for a freshly installed plugin (it reported enabled:false).
  it("marks an installed-but-disabled plugin as installed, not enabled", () => {
    const raw = [{ name: "awg_warp", installed: true, enabled: false }];
    expect(pluginStatusMap(raw)).toEqual({
      awg_warp: { installed: true, enabled: false },
    });
  });
  it("marks an enabled plugin as both installed and enabled", () => {
    const raw = [{ name: "awg_warp", installed: true, enabled: true }];
    const st = pluginStatusMap(raw).awg_warp;
    expect(st.installed).toBe(true);
    expect(st.enabled).toBe(true);
  });
  it("treats presence in the list as installed when the flag is absent", () => {
    expect(pluginStatusMap([{ name: "p" }]).p.installed).toBe(true);
  });
  it("omits a KNOWN plugin that is not in the raw list (not installed)", () => {
    expect(pluginStatusMap([]).awg_warp).toBeUndefined();
  });
  it("tolerates a null/garbage list", () => {
    expect(pluginStatusMap(null as unknown as any[])).toEqual({});
    expect(pluginStatusMap([null, { foo: 1 }] as unknown as any[])).toEqual({});
  });
});
