import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import vm from "node:vm";

// Mirrors the loader in test_descriptor_form_js.test.ts: descriptor_form.js is a
// LuCI fragment, not an ES module — strip the fragment header and rewrite the
// trailing `return L.Class.extend({...})` into a captured assignment, then eval
// in a node:vm sandbox with the CBI globals stubbed.
const VIEW_ROOT = resolve(
  import.meta.dir,
  "../../luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui",
);
const DESCRIPTOR_FORM_JS = resolve(VIEW_ROOT, "lib/descriptor_form.js");

function loadDescriptorForm(sandboxExtras: Record<string, unknown> = {}) {
  const src = readFileSync(DESCRIPTOR_FORM_JS, "utf8");
  const body = src
    .replace(/^'use strict';\s*/, "")
    .replace(/^'require [^']+';\s*/gm, "")
    .replace(/return L\.Class\.extend\((\{[\s\S]*\})\);?\s*$/, "__moduleExports = $1;");
  const sandbox: Record<string, unknown> = {
    __moduleExports: null,
    _: (s: unknown) => s,
    L: { Class: { extend: (o: unknown) => o } },
    ui: {},
    network: {},
    console,
    ...sandboxExtras,
  };
  vm.createContext(sandbox);
  vm.runInContext(`(function() {${body}})();`, sandbox, { filename: "descriptor_form.js" });
  return (sandbox as any).__moduleExports;
}

const form = {
  Flag: "Flag",
  ListValue: "ListValue",
  DynamicList: "DynamicList",
  TextValue: "TextValue",
  Value: "Value",
};
const DF = loadDescriptorForm({ form });
const tagField: (opt: any, name: string, control?: string) => void = DF.tagField;

// Minimal fake widget node exposing only the DOM API tagField touches.
function fakeNode() {
  const attrs: Record<string, string> = {};
  return { attrs, setAttribute(k: string, v: string) { attrs[k] = v; } };
}

describe("descriptor_form.js — tagField", () => {
  it("exports tagField", () => {
    expect(typeof tagField).toBe("function");
  });

  it("sets marker props even when the option has no renderWidget (stub path)", () => {
    const opt: any = {};
    tagField(opt, "server_uuid", "text");
    expect(opt._sbField).toBe("server_uuid");
    expect(opt._sbControl).toBe("text");
    expect(opt.renderWidget).toBeUndefined();
  });

  it("stamps data-sb-field + data-sb-control on the rendered widget node", () => {
    const node = fakeNode();
    const opt: any = { renderWidget: () => node };
    tagField(opt, "server", "text");
    const out = opt.renderWidget("sid", 0, "v");
    expect(out).toBe(node);
    expect(node.attrs["data-sb-field"]).toBe("server");
    expect(node.attrs["data-sb-control"]).toBe("text");
  });

  it("is null-safe when the original renderWidget returns null", () => {
    const opt: any = { renderWidget: () => null };
    tagField(opt, "x", "checkbox");
    expect(opt.renderWidget("sid", 0, "")).toBeNull(); // must not throw
  });

  it("composes over an existing renderWidget wrapper (wraps, does not replace)", () => {
    const node = fakeNode();
    let innerCalled = false;
    const opt: any = { renderWidget: () => { innerCalled = true; return node; } };
    tagField(opt, "flow", "list");
    opt.renderWidget("sid", 0, "");
    expect(innerCalled).toBe(true);
    expect(node.attrs["data-sb-field"]).toBe("flow");
  });
});
