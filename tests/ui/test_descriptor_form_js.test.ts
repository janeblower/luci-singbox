import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import vm from "node:vm";
import { describe, expect, it } from "vitest";

// tests/test_descriptor_form_js.sh — port of node-based unit tests for
// lib/descriptor_form.js::applyMaterialized().

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
};
const validators = {
  host: () => true,
  port: () => true,
  uuid: () => true,
  alpn: () => true,
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

const mat = {
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
      name: "server_port",
      type: "string",
      tab: "basic",
      required: true,
      validate: "port",
    },
    {
      name: "server_uuid",
      type: "string",
      tab: "basic",
      secret: true,
      validate: "uuid",
    },
    {
      name: "vless_flow",
      type: "enum",
      tab: "tls",
      values: ["", "xtls-rprx-vision"],
    },
    { name: "multi", type: "list", tab: "tls" },
    { name: "enabled", type: "bool", tab: "tls" },
  ],
};

describe("descriptor_form.js — applyMaterialized", () => {
  it("exports applyMaterialized", () => {
    expect(typeof applyMaterialized).toBe("function");
  });

  describe("basic vless outbound", () => {
    const { s, opts, tabs } = makeSection();
    applyMaterialized(s, "outbound", "vless", mat);

    it("taboption call count matches field count", () => {
      expect(opts.length).toBe(mat.fields.length);
    });

    it("tabs registered once (basic, tls)", () => {
      expect(tabs.length).toBe(2);
      expect(tabs.some((t) => t[0] === "basic")).toBe(true);
      expect(tabs.some((t) => t[0] === "tls")).toBe(true);
    });

    it("each option has exactly one depends arm {type:'vless'}", () => {
      for (const o of opts) {
        expect(o._depends.length).toBe(1);
        const d = o._depends[0];
        expect(Object.keys(d).length).toBe(1);
        expect(d.type).toBe("vless");
      }
    });

    it("widget mapping: string→Value, list→DynamicList, bool→Flag, enum→ListValue", () => {
      const widgetMap: Record<string, string> = {
        server: "Value",
        server_port: "Value",
        server_uuid: "Value",
        vless_flow: "ListValue",
        multi: "DynamicList",
        enabled: "Flag",
      };
      for (const o of opts) {
        expect(o._widget).toBe(widgetMap[o._name]);
      }
    });

    it("secret:true → password=true", () => {
      const uuidOpt = opts.find((o) => o._name === "server_uuid");
      expect(uuidOpt?.password).toBe(true);
    });

    it("required:true → rmempty=false", () => {
      const serverOpt = opts.find((o) => o._name === "server");
      expect(serverOpt?.rmempty).toBe(false);
    });

    it("enum values populated (2 entries for vless_flow)", () => {
      const flowOpt = opts.find((o) => o._name === "vless_flow");
      expect(flowOpt?._values.length).toBe(2);
    });

    it("optional field keeps rmempty=true and is modalonly", () => {
      const multiOpt = opts.find((o) => o._name === "multi");
      expect(multiOpt?.rmempty).toBe(true);
      expect(multiOpt?.modalonly).toBe(true);
    });
  });

  it("inbound discriminator uses 'protocol' not 'type'", () => {
    const { s: s2, opts: opts2 } = makeSection();
    applyMaterialized(s2, "inbound", "trojan", {
      sing_box_type: "trojan",
      tabs: ["basic"],
      fields: [{ name: "listen_port", type: "string", tab: "basic" }],
    });
    expect(opts2.length).toBe(1);
    expect(opts2[0]._depends.length).toBe(1);
    expect(Object.keys(opts2[0]._depends[0]).length).toBe(1);
    expect(opts2[0]._depends[0].protocol).toBe("trojan");
  });

  it("null/missing payload handled without throw", () => {
    const { s: sNull } = makeSection();
    expect(() => {
      applyMaterialized(sNull, "outbound", "vless", null);
      applyMaterialized(sNull, "outbound", "vless", { sing_box_type: "vless" });
    }).not.toThrow();
  });

  describe("dedup: shared (tab,name) across two protocols", () => {
    const { s: sDedup, opts: optsDedup } = makeSection();
    applyMaterialized(sDedup, "outbound", "protoA", {
      tabs: ["basic"],
      fields: [{ name: "shared", type: "string", tab: "basic" }],
    });
    applyMaterialized(sDedup, "outbound", "protoB", {
      tabs: ["basic"],
      fields: [{ name: "shared", type: "string", tab: "basic" }],
    });

    const sharedCalls = optsDedup.filter((o) => o._name === "shared");

    it("shared field deduped to one taboption", () => {
      expect(sharedCalls.length).toBe(1);
    });

    it("shared has depends from both protocols", () => {
      expect(sharedCalls[0]?._depends.length).toBe(2);
    });

    it("first depends arm is protoA", () => {
      expect(sharedCalls[0]?._depends[0]?.type).toBe("protoA");
    });

    it("second depends arm is protoB", () => {
      expect(sharedCalls[0]?._depends[1]?.type).toBe("protoB");
    });

    it("materialized fields default to modalonly", () => {
      expect(sharedCalls[0]?.modalonly).toBe(true);
    });
  });

  describe("enum-merge: union of values, no duplicates", () => {
    const { s: sEnumMerge, opts: optsEnumMerge } = makeSection();
    applyMaterialized(sEnumMerge, "outbound", "protoA", {
      tabs: ["basic"],
      fields: [
        { name: "mode", type: "enum", tab: "basic", values: ["", "x", "y"] },
      ],
    });
    applyMaterialized(sEnumMerge, "outbound", "protoB", {
      tabs: ["basic"],
      fields: [
        { name: "mode", type: "enum", tab: "basic", values: ["y", "z"] },
      ],
    });

    const modeCalls = optsEnumMerge.filter((o) => o._name === "mode");

    it("enum field deduped to one taboption", () => {
      expect(modeCalls.length).toBe(1);
    });

    it("enum mode has depends from both protocols", () => {
      expect(modeCalls[0]?._depends.length).toBe(2);
    });

    it("enum merge: values are ['', x, y, z] (union, no duplicates)", () => {
      const valueKeys = modeCalls[0]?._values.map((v: any[]) => v[0]);
      expect(valueKeys).toEqual(["", "x", "y", "z"]);
    });
  });

  it("advanced/parent_enabled/depends folded into one AND-arm (dns)", () => {
    const { s: sAdv, opts: optsAdv } = makeSection();
    applyMaterialized(sAdv, "dns", "vless", {
      tabs: ["tls"],
      fields: [
        {
          name: "reality_short_id",
          type: "string",
          tab: "tls",
          advanced: true,
          parent_enabled: "tls_enable",
          depends: { field: "tls_reality", value: "1" },
        },
      ],
    });
    const o = optsAdv.find((x: any) => x._name === "reality_short_id");
    expect(o._depends.length).toBe(1);
    const d = o._depends[0];
    expect(d.type).toBe("vless");
    expect(d.tls_reality).toBe("1");
    expect(d.tls_enable).toBe("1");
    expect(d._show_advanced_tls).toBe("1");
  });

  it("outbound advanced field has no _show_advanced gate (Bug 4)", () => {
    const { s: sNoAdv, opts: optsNoAdv } = makeSection();
    applyMaterialized(sNoAdv, "outbound", "vless", {
      tabs: ["tls"],
      fields: [
        {
          name: "reality_short_id",
          type: "string",
          tab: "tls",
          advanced: true,
          parent_enabled: "tls_enable",
          depends: { field: "tls_reality", value: "1" },
        },
      ],
    });
    const o = optsNoAdv.find((x: any) => x._name === "reality_short_id");
    expect(o._depends.length).toBe(1);
    const d = o._depends[0];
    expect(d.type).toBe("vless");
    expect(d.tls_reality).toBe("1");
    expect(d.tls_enable).toBe("1");
    expect("_show_advanced_tls" in d).toBe(false);
  });

  it("virtual field: write/remove suppressed, cfgvalue returns default", () => {
    const { s: sVirt, opts: optsVirt } = makeSection();
    applyMaterialized(sVirt, "outbound", "vless", {
      tabs: ["tls"],
      fields: [
        {
          name: "_show_advanced_tls",
          type: "bool",
          tab: "tls",
          virtual: true,
          default: "0",
        },
      ],
    });
    const o = optsVirt.find((x: any) => x._name === "_show_advanced_tls");
    expect(typeof o.write).toBe("function");
    expect(typeof o.remove).toBe("function");
    expect(o.cfgvalue()).toBe("0");
  });
});
