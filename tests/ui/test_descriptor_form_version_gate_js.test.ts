import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import vm from "node:vm";

// tests/test_descriptor_form_version_gate_js.sh — version gate behavior.
// Fields with min_version/max_version are disabled/hidden based on
// SbViewState.getCoreVersion() and getCompatOnly().

const VIEW_ROOT = resolve(
  import.meta.dir,
  "../../luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui",
);
const DESCRIPTOR_FORM_JS = resolve(VIEW_ROOT, "lib/descriptor_form.js");

// ---- section mock ----------------------------------------------------------

function makeSection() {
  const _opts: Record<string, any> = {};
  const _sbMatRegistry: Record<string, any> = {};
  return {
    _opts,
    _sbMatRegistry,
    tab() {},
    taboption(_tab: unknown, W: any, name: string, label: string) {
      const o = new W(name);
      o.title = label;
      _opts[name] = o;
      return o;
    },
  };
}

function mat(fields: unknown[]) {
  return { sing_box_type: "x", tabs: ["basic"], shared: {}, fields };
}

// ---- load descriptor_form with mutable version state ----------------------
//
// The shell test sets global._ and global.E then uses new Function(...) where
// 'return L.Class.extend(' is replaced by 'return (', so the function returns
// the exports object directly. We replicate this inside a vm context so that
// `_` and `E` are accessible as free variables.

interface VersionState {
  core: string;
  compatOnly: boolean;
}

function loadDF(vstate: VersionState) {
  const src = readFileSync(DESCRIPTOR_FORM_JS, "utf8");
  // Shell test strips 'use strict' + require lines, replaces 'return L.Class.extend('
  // with 'return (' so the body IS a function body returning the exports object.
  const body = src
    .replace(/^'use strict';\s*/, "")
    .replace(/^'require [^']+';\s*/gm, "")
    .replace(
      /return L\.Class\.extend\((\{[\s\S]*\})\);?\s*$/,
      "__exports = $1;",
    );

  function FakeOpt(this: any, name: string) {
    this.option = name;
    this.deps = [];
    this.readonly = false;
    this.title = name;
  }
  (FakeOpt.prototype as any).depends = function (d: unknown) {
    this.deps.push(d);
  };
  (FakeOpt.prototype as any).value = () => {};

  const form = {
    Flag: FakeOpt,
    Value: FakeOpt,
    ListValue: FakeOpt,
    DynamicList: FakeOpt,
  };

  const SbViewState = {
    getCoreVersion: () => vstate.core,
    getCompatOnly: () => vstate.compatOnly,
  };

  const SbCommon = {
    compareVersions: (a: string, b: string) => {
      const pa = String(a).split(".").map(Number);
      const pb = String(b).split(".").map(Number);
      for (let i = 0; i < 3; i++) {
        const x = pa[i] || 0;
        const y = pb[i] || 0;
        if (x > y) return 1;
        if (x < y) return -1;
      }
      return 0;
    },
  };

  const sandbox: Record<string, unknown> = {
    __exports: null,
    _: (s: unknown) => s,
    E: () => ({}),
    L: { Class: { extend: (o: unknown) => o } },
    form,
    ui: {},
    uci: { sections: () => [] },
    network: {},
    validators: {},
    SbViewState,
    SbCommon,
    console: { log: () => {}, error: () => {}, warn: () => {} },
  };

  vm.createContext(sandbox);
  vm.runInContext(`(function(){${body}})();`, sandbox, {
    filename: "descriptor_form.js",
  });
  return (sandbox as any).__exports;
}

// ---- tests -----------------------------------------------------------------

describe("descriptor_form.js version gate", () => {
  it("A: min_version gate, compatOnly=false → created, readonly, requires-note", () => {
    const vstate: VersionState = { core: "1.12", compatOnly: false };
    const mod = loadDF(vstate);
    const section = makeSection();
    mod.applyMaterialized(
      section,
      "dns",
      "x",
      mat([{ name: "f1", type: "string", tab: "basic", min_version: "1.13" }]),
    );
    const o = section._opts.f1;
    expect(o).toBeTruthy();
    expect(o.readonly).toBe(true);
    expect(/requires 1\.13/.test(o.title)).toBe(true);
  });

  it("B: min_version gate, compatOnly=true → NOT created (hidden)", () => {
    const vstate: VersionState = { core: "1.12", compatOnly: true };
    const mod = loadDF(vstate);
    const section = makeSection();
    mod.applyMaterialized(
      section,
      "dns",
      "x",
      mat([{ name: "f2", type: "string", tab: "basic", min_version: "1.13" }]),
    );
    expect(section._opts.f2).toBeFalsy();
  });

  it("C: max_version gate, core newer → created, readonly, removed-in note", () => {
    const vstate: VersionState = { core: "1.14", compatOnly: false };
    const mod = loadDF(vstate);
    const section = makeSection();
    mod.applyMaterialized(
      section,
      "dns",
      "x",
      mat([{ name: "f3", type: "string", tab: "basic", max_version: "1.13" }]),
    );
    const o = section._opts.f3;
    expect(o).toBeTruthy();
    expect(o.readonly).toBe(true);
    expect(/removed in 1\.13/.test(o.title)).toBe(true);
  });

  it("D: core matches min_version exactly → in-window, NOT readonly", () => {
    const vstate: VersionState = { core: "1.13", compatOnly: false };
    const mod = loadDF(vstate);
    const section = makeSection();
    mod.applyMaterialized(
      section,
      "dns",
      "x",
      mat([{ name: "f4", type: "string", tab: "basic", min_version: "1.13" }]),
    );
    const o = section._opts.f4;
    expect(o).toBeTruthy();
    expect(o.readonly).not.toBe(true);
  });
});
