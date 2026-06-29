import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import vm from "node:vm";
import { describe, expect, it } from "vitest";

// tests/test_audit_8_3.sh — regression for audit 8.3.
// makeVirtual() must persist the virtual toggle value in a session-scoped store
// (NOT UCI). write() mirrors the value into a session store; cfgvalue() restores
// it on re-render; write/remove are no-ops w.r.t. UCI.

const VIEW_ROOT = resolve(
  import.meta.dirname,
  "../../luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui",
);
const DESCRIPTOR_FORM_JS = resolve(VIEW_ROOT, "lib/descriptor_form.js");

function loadDescriptorForm() {
  const src = readFileSync(DESCRIPTOR_FORM_JS, "utf8");
  const body = src
    .replace(/^'use strict';\s*/, "")
    .replace(/^'require [^']+';\s*/gm, "")
    .replace(
      /return L\.Class\.extend\((\{[\s\S]*\})\);?\s*$/,
      "__moduleExports = $1;",
    );

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
  };
  const SbCommon = {
    compareVersions: () => 0,
  };

  const sandbox: Record<string, unknown> = {
    __moduleExports: null,
    _: (s: unknown) => s,
    L: { Class: { extend: (o: unknown) => o } },
    form,
    ui: {},
    validators,
    SbViewState,
    SbCommon,
    console,
  };
  vm.createContext(sandbox);
  vm.runInContext(`(function() {${body}})();`, sandbox, {
    filename: "descriptor_form.js",
  });
  return (sandbox as any).__moduleExports;
}

function makeSection() {
  const opts: any[] = [];
  const s = {
    tab: () => {},
    taboption: (
      _tab: string,
      _widget: unknown,
      name: string,
      _label: string,
    ) => {
      const o: any = {
        _name: name,
        option: name,
        _depends: [],
        rmempty: true,
        _uci: {},
      };
      o.depends = (d: unknown) => {
        o._depends.push(d);
        return o;
      };
      o.value = () => o;
      opts.push(o);
      return o;
    },
  };
  return { s, opts };
}

const VIRT = {
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
};

describe("audit 8.3 — makeVirtual session-scoped advanced-toggle persistence", () => {
  const DF = loadDescriptorForm();

  it("exports applyMaterialized", () => {
    expect(typeof DF.applyMaterialized).toBe("function");
  });

  it("write is a function on virtual opt", () => {
    const a = makeSection();
    DF.applyMaterialized(a.s, "outbound", "vless", VIRT);
    const oA = a.opts.find((x: any) => x._name === "_show_advanced_tls");
    expect(typeof oA.write).toBe("function");
  });

  it("remove is a function on virtual opt", () => {
    const a = makeSection();
    DF.applyMaterialized(a.s, "outbound", "vless", VIRT);
    const oA = a.opts.find((x: any) => x._name === "_show_advanced_tls");
    expect(typeof oA.remove).toBe("function");
  });

  it("initial cfgvalue is default '0'", () => {
    const a = makeSection();
    DF.applyMaterialized(a.s, "outbound", "vless", VIRT);
    const oA = a.opts.find((x: any) => x._name === "_show_advanced_tls");
    expect(oA.cfgvalue("cfg123")).toBe("0");
  });

  it("write does NOT touch UCI (no-op vs config)", () => {
    const a = makeSection();
    DF.applyMaterialized(a.s, "outbound", "vless", VIRT);
    const oA = a.opts.find((x: any) => x._name === "_show_advanced_tls");
    oA.write("cfg123", "1");
    expect(Object.keys(oA._uci).length).toBe(0);
  });

  it("cfgvalue reflects stored '1' after write", () => {
    const a = makeSection();
    DF.applyMaterialized(a.s, "outbound", "vless", VIRT);
    const oA = a.opts.find((x: any) => x._name === "_show_advanced_tls");
    oA.write("cfg123", "1");
    expect(oA.cfgvalue("cfg123")).toBe("1");
  });

  it("re-open (new opt object) restores stored '1' from session (core 8.3 fix)", () => {
    // Modal open #1: write value into session store
    const a = makeSection();
    DF.applyMaterialized(a.s, "outbound", "vless", VIRT);
    const oA = a.opts.find((x: any) => x._name === "_show_advanced_tls");
    oA.write("cfg123", "1");

    // Modal open #2: brand new option object for the same section
    const b = makeSection();
    DF.applyMaterialized(b.s, "outbound", "vless", VIRT);
    const oB = b.opts.find((x: any) => x._name === "_show_advanced_tls");
    expect(oB.cfgvalue("cfg123")).toBe("1");
  });

  it("different section id is independent (no cross-section leakage)", () => {
    const a = makeSection();
    DF.applyMaterialized(a.s, "outbound", "vless", VIRT);
    const oA = a.opts.find((x: any) => x._name === "_show_advanced_tls");
    oA.write("cfg123", "1");

    const b = makeSection();
    DF.applyMaterialized(b.s, "outbound", "vless", VIRT);
    const oB = b.opts.find((x: any) => x._name === "_show_advanced_tls");
    expect(oB.cfgvalue("cfgOTHER")).toBe("0");
  });

  it("cfgvalue back to default after remove", () => {
    const a = makeSection();
    DF.applyMaterialized(a.s, "outbound", "vless", VIRT);
    const oA = a.opts.find((x: any) => x._name === "_show_advanced_tls");
    oA.write("cfg123", "1");
    oA.remove("cfg123");
    expect(oA.cfgvalue("cfg123")).toBe("0");
  });
});
