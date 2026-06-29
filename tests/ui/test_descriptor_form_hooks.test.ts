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
    .replace(
      /return L\.Class\.extend\((\{[\s\S]*\})\);?\s*$/,
      "__moduleExports = $1;",
    );
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
  vm.runInContext(`(function() {${body}})();`, sandbox, {
    filename: "descriptor_form.js",
  });
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
const tagField: (opt: any, name: string, control?: string) => void =
  DF.tagField;

// Minimal fake widget node exposing only the DOM API tagField touches.
function fakeNode() {
  const attrs: Record<string, string> = {};
  return {
    attrs,
    setAttribute(k: string, v: string) {
      attrs[k] = v;
    },
  };
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
    const opt: any = {
      renderWidget: () => {
        innerCalled = true;
        return node;
      },
    };
    tagField(opt, "flow", "list");
    opt.renderWidget("sid", 0, "");
    expect(innerCalled).toBe(true);
    expect(node.attrs["data-sb-field"]).toBe("flow");
  });
});

// --- integration: every materialized field carries the hook -----------------
const validators = { host: () => true, port: () => true, uuid: () => true };
const SbViewState = {
  getCoreVersion: () => "",
  getCompatOnly: () => false,
  getSchema: () => ({}),
};
const SbCommon = { compareVersions: () => 0 };
const DF2 = loadDescriptorForm({ form, validators, SbViewState, SbCommon });

function makeSection() {
  const opts: any[] = [];
  const tabs: [string, string][] = [];
  const s: any = {
    tab(name: string, title: string) {
      tabs.push([name, title]);
    },
    taboption(tab: string, widget: unknown, name: string, label: string) {
      const o: any = {
        _tab: tab,
        _widget: widget,
        _name: name,
        _label: label,
        _depends: [],
        _values: [],
        rmempty: true,
      };
      o.depends = (d: unknown) => {
        o._depends.push(d);
        return o;
      };
      o.value = (k: unknown, v: unknown) => {
        o._values.push([k, v]);
        return o;
      };
      opts.push(o);
      return o;
    },
    option(widget: unknown, name: string, label: string) {
      return s.taboption("basic", widget, name, label);
    },
  };
  return { s, opts, tabs };
}

const wireMat = {
  sing_box_type: "vless",
  tabs: ["basic", "tls"],
  fields: [
    {
      name: "server",
      type: "string",
      tab: "basic",
      required: true,
      validate: "host",
    },
    {
      name: "vless_flow",
      type: "enum",
      tab: "tls",
      values: ["", "xtls-rprx-vision"],
    },
    { name: "multi", type: "list", tab: "tls" },
    { name: "enabled_flag", type: "bool", tab: "tls" },
    { name: "raw_json", type: "string", tab: "tls", multiline: true },
  ],
};

describe("descriptor_form.js — tagField wiring", () => {
  it("applyMaterialized tags every field with name + control kind", () => {
    const { s, opts } = makeSection();
    DF2.applyMaterialized(s, "outbound", "vless", wireMat);
    const byName: Record<string, any> = {};
    for (const o of opts) byName[o._name] = o;
    expect(opts.length).toBe(wireMat.fields.length);
    expect(opts.every((o) => o._sbField === o._name)).toBe(true);
    expect(byName.server._sbControl).toBe("text");
    expect(byName.vless_flow._sbControl).toBe("list");
    expect(byName.multi._sbControl).toBe("dynamic");
    expect(byName.enabled_flag._sbControl).toBe("checkbox");
    expect(byName.raw_json._sbControl).toBe("textarea");
  });

  it("applyMaterializedNamed tags every singleton field", () => {
    const { s, opts } = makeSection();
    DF2.applyMaterializedNamed(s, "cache", "cache", {
      fields: [
        { name: "enabled", type: "bool", tab: "basic" },
        { name: "store_rdrc", type: "string", tab: "basic" },
      ],
    });
    expect(opts.length).toBe(2);
    expect(opts.every((o) => o._sbField === o._name)).toBe(true);
    expect(opts.find((o) => o._name === "enabled")._sbControl).toBe("checkbox");
    expect(opts.find((o) => o._name === "store_rdrc")._sbControl).toBe("text");
  });
});
