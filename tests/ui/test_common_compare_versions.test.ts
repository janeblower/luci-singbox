import { describe, expect, it } from "bun:test";
import { resolve } from "node:path";
import { loadLuciModule } from "../helpers/luci.ts";

// Regression for uic-7: compareVersions must compare ALL components (not just
// the first 3) and strip pre-release/build suffixes.
const COMMON_JS = resolve(
  import.meta.dir,
  "../../luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/lib/common.js",
);

const { exports: C } = loadLuciModule(COMMON_JS, {
  _: (s: unknown) => s,
  E: () => ({}),
  ui: { addNotification() {}, showModal() {}, hideModal() {} },
  form: { Value: () => {}, ListValue: () => {} },
  uci: { sections: () => [], rename() {} },
  Promise,
});

describe("common.compareVersions (uic-7)", () => {
  it("compares the 4th+ component, not just the first three", () => {
    expect(C.compareVersions("1.12.0.1", "1.12.0")).toBe(1);
    expect(C.compareVersions("1.12.0", "1.12.0.1")).toBe(-1);
    expect(C.compareVersions("1.12.0.1", "1.12.0.1")).toBe(0);
  });

  it("strips pre-release/build suffixes before comparing", () => {
    expect(C.compareVersions("1.13.0-rc1", "1.13.0")).toBe(0);
    expect(C.compareVersions("1.14.0+build5", "1.14.0")).toBe(0);
    expect(C.compareVersions("1.14.0-beta", "1.13.9")).toBe(1);
  });

  it("orders numerically, not lexically", () => {
    expect(C.compareVersions("1.12.5", "1.12.10")).toBe(-1);
    expect(C.compareVersions("1.2", "1.10")).toBe(-1);
  });

  it("fails open (0) when either version is empty/unknown", () => {
    expect(C.compareVersions("", "1.12.0")).toBe(0);
    expect(C.compareVersions("1.12.0", "")).toBe(0);
  });
});
