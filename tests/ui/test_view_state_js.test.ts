import { describe, expect, it } from "bun:test";
import { execSync } from "node:child_process";
import { resolve } from "node:path";
import { loadLuciModule } from "../helpers/luci.ts";

// tests/test_view_state_js.sh — the schema cache must live in a module
// singleton (lib/view_state.js), not on window (spec S2-5).

const VIEW_ROOT = resolve(
  import.meta.dir,
  "../../luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui",
);

const VIEW_STATE_JS = resolve(VIEW_ROOT, "lib/view_state.js");

describe("view_state.js", () => {
  // Guard: no window.singboxUi* writes/reads remain anywhere in the view tree.
  it("no leftover window.singboxUi* references in view tree (S2-5)", () => {
    const result = execSync(
      `grep -RHn "window\\.singboxUi" "${VIEW_ROOT}" || true`,
      {
        encoding: "utf8",
      },
    );
    expect(result.trim()).toBe("");
  });

  describe("module exports (S2-5)", () => {
    const { exports: VS } = loadLuciModule(VIEW_STATE_JS, {
      Object,
    });

    it("exports getSchema function", () => {
      expect(typeof VS.getSchema).toBe("function");
    });

    it("exports setSchema function", () => {
      expect(typeof VS.setSchema).toBe("function");
    });

    it("schema round-trips through set/get", () => {
      VS.setSchema({ inbound: { tproxy: {} } });
      expect(VS.getSchema().inbound.tproxy).not.toBeUndefined();
    });
  });
});
