import { describe, expect, it } from "bun:test";
import { resolve } from "node:path";
import { loadLuciModule } from "../helpers/luci.ts";

// tests/test_view_state_compat_js.sh — getCompatOnly/setCompatOnly on view_state.js

const VIEW_STATE_JS = resolve(
  import.meta.dir,
  "../../luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/lib/view_state.js",
);

const { exports: mod } = loadLuciModule(VIEW_STATE_JS, { Object });

describe("view_state.js compat mode", () => {
  it("exports getCompatOnly function", () => {
    expect(typeof mod.getCompatOnly).toBe("function");
  });

  it("default value of getCompatOnly is false", () => {
    expect(mod.getCompatOnly()).toBe(false);
  });

  it("setCompatOnly(true) persists", () => {
    mod.setCompatOnly(true);
    expect(mod.getCompatOnly()).toBe(true);
  });
});
