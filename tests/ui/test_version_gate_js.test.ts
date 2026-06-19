import { describe, expect, it } from "bun:test";
import { resolve } from "node:path";
import { loadLuciModule } from "../helpers/luci.ts";

// tests/test_version_gate_js.sh — unit tests for compareVersions in lib/common.js.

const COMMON_JS = resolve(
  import.meta.dir,
  "../../luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/lib/common.js",
);

const { exports: C } = loadLuciModule(COMMON_JS, {
  _: (s: unknown) => s,
  E: () => ({}),
  form: { ListValue: () => {}, Value: () => {} },
  ui: { showModal() {}, hideModal() {} },
  uci: { sections: () => [], rename() {} },
  window: { navigator: null },
  document: {
    body: { appendChild() {}, removeChild() {} },
    execCommand: () => false,
  },
  Promise,
  Object,
  Array,
  String,
  parseInt,
});

describe("compareVersions", () => {
  it("1.12.0 < 1.13.0 → -1", () => {
    expect(C.compareVersions("1.12.0", "1.13.0")).toBe(-1);
  });

  it("1.14.0 > 1.13.0 → 1", () => {
    expect(C.compareVersions("1.14.0", "1.13.0")).toBe(1);
  });

  it("1.13.0 == 1.13.0 → 0", () => {
    expect(C.compareVersions("1.13.0", "1.13.0")).toBe(0);
  });

  it("'' vs 1.13.0 → 0 (fail open)", () => {
    expect(C.compareVersions("", "1.13.0")).toBe(0);
  });

  it("1.13.0 vs '' → 0 (fail open)", () => {
    expect(C.compareVersions("1.13.0", "")).toBe(0);
  });
});
