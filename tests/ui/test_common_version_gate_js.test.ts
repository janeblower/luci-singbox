import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

// tests/test_common_version_gate_js.sh — node tests for applyVersionGate in common.js.
// Exercises min_version gating (requires X.Y+) and max_version gating (removed in X.Y).
//
// Note: this test uses the same new Function() sandbox as the original .sh to
// match the way the shell test loads common.js (not via loadLuciModule / vm).

const COMMON_JS = resolve(
  import.meta.dirname,
  "../../luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/lib/common.js",
);

function loadCommon() {
  const src = readFileSync(COMMON_JS, "utf8");
  const body = src
    .replace(/^'use strict';\s*/, "")
    .replace(/'require [^']*';\s*/g, "")
    .replace(/return L\.Class\.extend\(/, "return (");
  const form = {};
  const uci = {};
  const ui = {};
  // Inject globals that common.js relies on when run via new Function
  // (mirrors the original shell test: global._=(s)=>s; global.E=()=>({}))
  const _g = (s: unknown) => s;
  const _E = () => ({});
  // biome-ignore lint/security/noGlobalEval: test harness mirrors the original .sh approach
  const mod = new Function("_", "E", "form", "uci", "ui", body)(
    _g,
    _E,
    form,
    uci,
    ui,
  );
  return mod;
}

// schema types:
//   a: min_version 1.14 — gated when core=1.12 (core < 1.14)
//   b: max_version 1.11 — gated when core=1.12 (core > 1.11, type was removed)
//   c: no gate
//   d: max_version 1.12 — BOUNDARY: gated when core=1.12 (max_version is the
//      removal version, exclusive upper bound → removed AT 1.12)
const schema = {
  a: { min_version: "1.14" },
  b: { max_version: "1.11" },
  c: {},
  d: { max_version: "1.12" },
};

function mkSelect() {
  const opts = [
    { value: "a", disabled: false, textContent: "a" },
    { value: "b", disabled: false, textContent: "b" },
    { value: "c", disabled: false, textContent: "c" },
    { value: "d", disabled: false, textContent: "d" },
  ];
  return { tagName: "SELECT", options: opts, querySelector: () => null };
}

describe("applyVersionGate (common.js)", () => {
  const mod = loadCommon();

  describe("compatOnly=false (disable-with-note mode)", () => {
    const o: any = {
      renderWidget() {
        return mkSelect();
      },
      value() {},
      validate: null,
    };
    mod.applyVersionGate(o, schema, "1.12", false);
    const node = o.renderWidget();
    const a = node.options.find((x: any) => x.value === "a");
    const b = node.options.find((x: any) => x.value === "b");
    const c = node.options.find((x: any) => x.value === "c");
    const d = node.options.find((x: any) => x.value === "d");

    it("min_version 1.14 option is disabled when core=1.12", () => {
      expect(a.disabled).toBe(true);
    });

    it("min_version 1.14 option label contains 'requires 1.14'", () => {
      expect(/requires 1\.14/.test(a.textContent)).toBe(true);
    });

    it("max_version 1.11 option is disabled when core=1.12 (removed in 1.11)", () => {
      expect(b.disabled).toBe(true);
    });

    it("max_version 1.11 option label contains 'removed in 1.11'", () => {
      expect(/removed in 1\.11/.test(b.textContent)).toBe(true);
    });

    it("in-window option c is NOT disabled", () => {
      expect(c.disabled).toBe(false);
    });

    it("max_version 1.12 (boundary) is disabled when core=1.12 (removed AT 1.12)", () => {
      expect(d.disabled).toBe(true);
    });

    it("boundary option label contains 'removed in 1.12'", () => {
      expect(/removed in 1\.12/.test(d.textContent)).toBe(true);
    });
  });

  describe("compatOnly=true (hide gated options)", () => {
    const o2: any = {
      renderWidget() {
        return mkSelect();
      },
      value() {},
      validate: null,
    };
    mod.applyVersionGate(o2, schema, "1.12", true);

    it("validate rejects gated value 'a' when compatOnly=true", () => {
      const result = o2.validate(null, "a");
      expect(result).not.toBe(true);
    });

    it("validate accepts in-window value 'c' when compatOnly=true", () => {
      const result = o2.validate(null, "c");
      expect(result).toBe(true);
    });
  });
});
