import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import vm from "node:vm";
import { describe, expect, it } from "vitest";

// tests/ui/test_descriptor_form_multiline_js.test.ts — regression test for
// uic-3: multiline string fields must render as TextValue with rows/monospace
// styling instead of cramped single-line form.Value.

const VIEW_ROOT = resolve(
  import.meta.dirname,
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
  Value: "Value",
  TextValue: "TextValue",
};
const validators = {
  host: () => true,
  port: () => true,
};
const SbViewState = {
  getCoreVersion: () => "",
  getCompatOnly: () => false,
  getSchema: () => ({}),
};
const SbCommon = { compareVersions: () => 0 };

const DF = loadDescriptorForm({ form, validators, SbViewState, SbCommon });
const applyMaterialized: (
  s: any,
  kind: string,
  proto: string,
  mat: any,
) => void = DF.applyMaterialized;

function makeSection() {
  const opts: any[] = [];
  const tabs: [string, string][] = [];
  const s = {
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
  };
  return { s, opts, tabs };
}

describe("descriptor_form.js — multiline support (uic-3)", () => {
  it("multiline:true → TextValue widget", () => {
    const { s, opts } = makeSection();
    applyMaterialized(s, "outbound", "json", {
      tabs: ["basic"],
      fields: [
        {
          name: "raw_json",
          type: "string",
          tab: "basic",
          required: true,
          multiline: true,
        },
      ],
    });
    const jsonOpt = opts.find((o) => o._name === "raw_json");
    expect(jsonOpt?._widget).toBe("TextValue");
  });

  it("multiline field gets rows and monospace styling", () => {
    const { s, opts } = makeSection();
    applyMaterialized(s, "outbound", "json", {
      tabs: ["basic"],
      fields: [
        {
          name: "raw_json",
          type: "string",
          tab: "basic",
          required: true,
          multiline: true,
        },
      ],
    });
    const jsonOpt = opts.find((o) => o._name === "raw_json");
    expect(jsonOpt?.rows).toBe(12);
    expect(jsonOpt?.monospace).toBe(true);
  });

  it("multiline false (or absent) → Value widget", () => {
    const { s, opts } = makeSection();
    applyMaterialized(s, "outbound", "vless", {
      tabs: ["basic"],
      fields: [
        {
          name: "server",
          type: "string",
          tab: "basic",
          required: true,
        },
      ],
    });
    const serverOpt = opts.find((o) => o._name === "server");
    expect(serverOpt?._widget).toBe("Value");
    expect(serverOpt?.rows).toBeUndefined();
    expect(serverOpt?.monospace).toBeUndefined();
  });

  it("ssh private_key multiline field renders as TextValue", () => {
    const { s, opts } = makeSection();
    applyMaterialized(s, "outbound", "ssh", {
      tabs: ["basic"],
      fields: [
        {
          name: "private_key",
          type: "string",
          tab: "basic",
          secret: true,
          multiline: true,
        },
      ],
    });
    const keyOpt = opts.find((o) => o._name === "private_key");
    // Multiline takes precedence — TextValue for better UX with PEM blocks
    expect(keyOpt?._widget).toBe("TextValue");
    expect(keyOpt?.rows).toBe(12);
    expect(keyOpt?.monospace).toBe(true);
    // multiline wins over secret: a masked single-line input (and its eye
    // toggle) is unusable for a multi-line PEM key, so the password decoration
    // is intentionally NOT applied to the textarea.
    expect(keyOpt?.password).toBeUndefined();
  });

  it("sharelink raw_link multiline field renders as TextValue", () => {
    const { s, opts } = makeSection();
    applyMaterialized(s, "outbound", "sharelink", {
      tabs: ["basic"],
      fields: [
        {
          name: "raw_link",
          type: "string",
          tab: "basic",
          required: true,
          multiline: true,
        },
      ],
    });
    const linkOpt = opts.find((o) => o._name === "raw_link");
    expect(linkOpt?._widget).toBe("TextValue");
    expect(linkOpt?.rows).toBe(12);
    expect(linkOpt?.monospace).toBe(true);
  });
});
