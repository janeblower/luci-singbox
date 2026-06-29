import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import vm from "node:vm";
import { describe, expect, it } from "vitest";

// tests/test_descriptor_form_dynamic_js.sh — port of dynamic-source selector
// tests for lib/descriptor_form.js::applyMaterialized().

const VIEW_ROOT = resolve(
  import.meta.dirname,
  "../../luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui",
);
const DESCRIPTOR_FORM_JS = resolve(VIEW_ROOT, "lib/descriptor_form.js");

function mkWidget(tag: string) {
  function W(this: any) {}
  (W as any)._tag = tag;
  W.prototype.load = function (this: any) {
    this._baseLoaded = true;
    return `base:${tag}`;
  };
  return W as any;
}

const form = {
  Flag: mkWidget("Flag"),
  ListValue: mkWidget("ListValue"),
  DynamicList: mkWidget("DynamicList"),
  MultiValue: mkWidget("MultiValue"),
  Value: mkWidget("Value"),
};

const validators = { host: () => true, port: () => true, uuid: () => true };

const uci: any = {
  sections(config: string, type: string) {
    if (config === "singbox-ui" && type === "outbound") {
      return [{ ".name": "proxy_a" }, { ".name": "proxy_b" }];
    }
    if (config === "singbox-ui" && type === "dns_server") {
      return [{ ".name": "cloudflare", type: "https" }];
    }
    if (config === "network" && type === "interface") {
      return [{ ".name": "loopback" }, { ".name": "lan" }, { ".name": "wan" }];
    }
    if (config === "singbox-ui" && type === "ruleset") {
      return [
        { ".name": "rs_geoip", type: "remote" },
        { ".name": "rs_ads", type: "local" },
      ];
    }
    if (config === "singbox-ui" && type === "route_rule") {
      return [
        { ".name": "rule_default", type: "default" },
        { ".name": "rule_logical", type: "logical" },
      ];
    }
    if (config === "singbox-ui" && type === "inbound") {
      return [
        { ".name": "tp1", enabled: "1", protocol: "tproxy", nft_rules: "1" },
        { ".name": "tp2", enabled: "1", protocol: "tproxy" },
      ];
    }
    return [];
  },
  get(_config: string, sid: string, opt: string) {
    const rows: any[] = uci.sections("singbox-ui", "inbound");
    const row = rows.filter((r: any) => r[".name"] === sid)[0];
    return row ? row[opt] : undefined;
  },
  _setCalls: [] as any[],
  set(_config: string, sid: string, opt: string, val: string) {
    uci._setCalls.push([sid, opt, val]);
  },
};

const SbViewState: any = {
  _ver: "",
  _compatOnly: false,
  getCoreVersion() {
    return SbViewState._ver;
  },
  setCoreVersion(v: string) {
    SbViewState._ver = v || "";
  },
  getCompatOnly() {
    return SbViewState._compatOnly;
  },
};
const SbCommon = {
  compareVersions(a: string, b: string) {
    const pa = String(a).split(".").map(Number);
    const pb = String(b).split(".").map(Number);
    const len = Math.max(pa.length, pb.length);
    for (let i = 0; i < len; i++) {
      const na = pa[i] || 0;
      const nb = pb[i] || 0;
      if (na !== nb) return na > nb ? 1 : -1;
    }
    return 0;
  },
};
const network = {
  getDevices() {
    return Promise.resolve([
      { getName: () => "br-lan" },
      { getName: () => "eth0" },
    ]);
  },
};

function loadDescriptorForm() {
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
    form,
    ui: {},
    validators,
    uci,
    network,
    SbViewState,
    SbCommon,
    console,
    Promise,
  };
  vm.createContext(sandbox);
  vm.runInContext(`(function() {${body}})();`, sandbox, {
    filename: "descriptor_form.js",
  });
  return (sandbox as any).__moduleExports;
}

const DF = loadDescriptorForm();
const applyMaterialized: (
  s: any,
  kind: string,
  proto: string,
  mat: any,
) => void = DF.applyMaterialized;

function makeSection() {
  const opts: any[] = [];
  const s = {
    tab() {},
    taboption(_tab: string, widget: unknown, name: string, _label: string) {
      const o: any = {
        _tab,
        _widget: widget,
        _name: name,
        _depends: [],
        _values: [],
        rmempty: true,
        keylist: [],
        vallist: [],
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
  return { s, opts };
}

function findOpt(opts: any[], name: string) {
  return opts.find((o) => o._name === name);
}
function keysOf(opt: any): string[] {
  return opt._values.map((v: any[]) => v[0]);
}

describe("descriptor_form.js — dynamic selectors", () => {
  describe("1. dynamic:outbounds + type:string → ListValue", () => {
    const { s, opts } = makeSection();
    applyMaterialized(s, "outbound", "vless", {
      tabs: ["dial"],
      fields: [
        { name: "detour", type: "string", tab: "dial", dynamic: "outbounds" },
      ],
    });
    const o = findOpt(opts, "detour");

    it("widget is ListValue", () => {
      expect(o?._widget).toBe(form.ListValue);
    });

    it("load() populates (none) + outbound tags", () => {
      expect(typeof o?.load).toBe("function");
      o.load.call(o, "sid");
      const k = keysOf(o);
      expect(k.length).toBe(3);
      expect(k[0]).toBe("");
      expect(k.indexOf("proxy_a")).toBeGreaterThanOrEqual(0);
      expect(k.indexOf("proxy_b")).toBeGreaterThanOrEqual(0);
    });
  });

  describe("1b. dynamic:outbounds + type:list → DynamicList, excludes own section_id", () => {
    const { s, opts } = makeSection();
    applyMaterialized(s, "outbound", "selector", {
      tabs: ["basic"],
      fields: [
        { name: "outbounds", type: "list", tab: "basic", dynamic: "outbounds" },
      ],
    });
    const o = findOpt(opts, "outbounds");

    it("widget is DynamicList", () => {
      expect(o?._widget).toBe(form.DynamicList);
    });

    it("load() suggests tags, excludes own section_id", () => {
      expect(typeof o?.load).toBe("function");
      o.load.call(o, "proxy_a");
      const k = keysOf(o);
      expect(k.indexOf("proxy_b")).toBeGreaterThanOrEqual(0);
      expect(k.indexOf("proxy_a")).toBe(-1);
    });
  });

  describe("1c. dynamic:outbounds + type:string (detour2) → ListValue", () => {
    const { s, opts } = makeSection();
    applyMaterialized(s, "outbound", "vless", {
      tabs: ["dial"],
      fields: [
        { name: "detour2", type: "string", tab: "dial", dynamic: "outbounds" },
      ],
    });

    it("widget is ListValue (single-select unchanged)", () => {
      const o = findOpt(opts, "detour2");
      expect(o?._widget).toBe(form.ListValue);
    });
  });

  describe("2. dynamic:interfaces → ListValue, drops loopback", () => {
    const { s, opts } = makeSection();
    applyMaterialized(s, "outbound", "vless", {
      tabs: ["dial"],
      fields: [
        {
          name: "bind_interface",
          type: "string",
          tab: "dial",
          dynamic: "interfaces",
        },
      ],
    });
    const o = findOpt(opts, "bind_interface");

    it("widget is ListValue", () => {
      expect(o?._widget).toBe(form.ListValue);
    });

    it("load() lists logical ifaces, drops loopback", () => {
      o.load.call(o, "sid");
      const k = keysOf(o);
      expect(k.indexOf("lan")).toBeGreaterThanOrEqual(0);
      expect(k.indexOf("wan")).toBeGreaterThanOrEqual(0);
      expect(k.indexOf("loopback")).toBe(-1);
    });
  });

  describe("3. dynamic:devices + type:list → DynamicList, async netdev", () => {
    const { s, opts } = makeSection();
    applyMaterialized(s, "inbound", "tproxy", {
      tabs: ["basic"],
      fields: [
        { name: "interface", type: "list", tab: "basic", dynamic: "devices" },
      ],
    });
    const o = findOpt(opts, "interface");

    it("widget is DynamicList", () => {
      expect(o?._widget).toBe(form.DynamicList);
    });

    it("load() resolves netdev suggestions (async)", async () => {
      const r = o.load.call(o, "sid");
      expect(r && typeof r.then).toBe("function");
      await r;
      const k = keysOf(o);
      expect(k.indexOf("br-lan")).toBeGreaterThanOrEqual(0);
      expect(k.indexOf("eth0")).toBeGreaterThanOrEqual(0);
    });
  });

  describe("4. string + static values → Value (combobox, free entry)", () => {
    const { s, opts } = makeSection();
    applyMaterialized(s, "outbound", "shadowsocks", {
      tabs: ["basic"],
      fields: [
        {
          name: "plugin",
          type: "string",
          tab: "basic",
          values: ["obfs-local", "v2ray-plugin", "shadow-tls"],
        },
      ],
    });
    const o = findOpt(opts, "plugin");

    it("widget is Value (combobox, NOT strict ListValue)", () => {
      expect(o?._widget).toBe(form.Value);
    });

    it("static value suggestions populated", () => {
      const k = keysOf(o);
      expect(k.length).toBe(3);
      expect(k.indexOf("obfs-local")).toBeGreaterThanOrEqual(0);
      expect(k.indexOf("shadow-tls")).toBeGreaterThanOrEqual(0);
    });
  });

  describe("5. list + static values → DynamicList (ALPN)", () => {
    const { s, opts } = makeSection();
    applyMaterialized(s, "outbound", "vless", {
      tabs: ["tls"],
      fields: [
        {
          name: "tls_alpn",
          type: "list",
          tab: "tls",
          values: ["h2", "http/1.1", "h3"],
        },
      ],
    });
    const o = findOpt(opts, "tls_alpn");

    it("widget is DynamicList", () => {
      expect(o?._widget).toBe(form.DynamicList);
    });

    it("suggestions populated", () => {
      const k = keysOf(o);
      expect(k.indexOf("h2")).toBeGreaterThanOrEqual(0);
      expect(k.indexOf("http/1.1")).toBeGreaterThanOrEqual(0);
      expect(k.indexOf("h3")).toBeGreaterThanOrEqual(0);
    });
  });

  describe("6. dynamic:rulesets + type:list → DynamicList", () => {
    const { s, opts } = makeSection();
    applyMaterialized(s, "route_rule", "default", {
      tabs: ["match"],
      fields: [
        { name: "rule_set", type: "list", tab: "match", dynamic: "rulesets" },
      ],
    });
    const o = findOpt(opts, "rule_set");

    it("widget is DynamicList", () => {
      expect(o?._widget).toBe(form.DynamicList);
    });

    it("load() populates ruleset suggestions", () => {
      expect(typeof o?.load).toBe("function");
      o.load.call(o, "sid");
      const k = keysOf(o);
      expect(k.indexOf("rs_geoip")).toBeGreaterThanOrEqual(0);
      expect(k.indexOf("rs_ads")).toBeGreaterThanOrEqual(0);
    });
  });

  describe("7. per-field min_version gate", () => {
    it("7a. core unknown → fail-open, both fields rendered", () => {
      SbViewState._ver = "";
      const { s, opts } = makeSection();
      applyMaterialized(s, "outbound", "vless", {
        tabs: ["basic"],
        fields: [
          {
            name: "new_field",
            type: "string",
            tab: "basic",
            min_version: "99.0.0",
          },
          { name: "old_field", type: "string", tab: "basic" },
        ],
      });
      expect(findOpt(opts, "new_field")).not.toBeUndefined();
      expect(findOpt(opts, "old_field")).not.toBeUndefined();
    });

    it("7b. 1.12 core, min_version 1.14 → field disabled (readonly)", () => {
      SbViewState._ver = "1.12.0";
      const { s, opts } = makeSection();
      applyMaterialized(s, "outbound", "vless", {
        tabs: ["basic"],
        fields: [
          {
            name: "future_field",
            type: "string",
            tab: "basic",
            min_version: "1.14.0",
          },
          {
            name: "compat_field",
            type: "string",
            tab: "basic",
            min_version: "1.12.0",
          },
        ],
      });
      expect(findOpt(opts, "future_field")?.readonly).toBe(true);
      expect(findOpt(opts, "compat_field")?.readonly).not.toBe(true);
      SbViewState._ver = "";
    });

    it("7c. compatOnly=true → future field hidden", () => {
      SbViewState._ver = "1.12.0";
      SbViewState._compatOnly = true;
      const { s, opts } = makeSection();
      applyMaterialized(s, "outbound", "vless", {
        tabs: ["basic"],
        fields: [
          {
            name: "future_field",
            type: "string",
            tab: "basic",
            min_version: "1.14.0",
          },
        ],
      });
      SbViewState._compatOnly = false;
      SbViewState._ver = "";
      expect(findOpt(opts, "future_field")).toBeUndefined();
    });
  });

  describe("8. exclusive bool: owner-gating for nft_rules", () => {
    const { s, opts } = makeSection();
    applyMaterialized(s, "inbound", "tproxy", {
      tabs: ["basic"],
      fields: [
        { name: "nft_rules", type: "bool", tab: "basic", exclusive: true },
      ],
    });
    const o = findOpt(opts, "nft_rules");

    it("exclusive: owner helper attached", () => {
      expect(typeof o?._exclusiveOwner).toBe("function");
    });

    it("exclusive: tp1 owns nft rules", () => {
      expect(o._exclusiveOwner("tp2")).toBe("tp1");
    });

    it("exclusive: non-owner write forced to 0", () => {
      uci._setCalls = [];
      o.write("tp2", "1");
      const w2 = uci._setCalls.filter((c: any[]) => c[0] === "tp2")[0];
      expect(w2?.[2]).toBe("0");
    });

    it("exclusive: owner write keeps 1", () => {
      uci._setCalls = [];
      o.write("tp1", "1");
      const w1 = uci._setCalls.filter((c: any[]) => c[0] === "tp1")[0];
      expect(w1?.[2]).toBe("1");
    });
  });

  describe("9. exclusive: unset first inbound qualifies as owner", () => {
    it("tpA (nft_rules unset) is owner over tpB (nft_rules=1)", () => {
      const origSections = uci.sections;
      uci.sections = (config: string, type: string) => {
        if (config === "singbox-ui" && type === "inbound") {
          return [
            { ".name": "tpA", enabled: "1", protocol: "tproxy" },
            {
              ".name": "tpB",
              enabled: "1",
              protocol: "tproxy",
              nft_rules: "1",
            },
          ];
        }
        return origSections(config, type);
      };
      const { s, opts } = makeSection();
      applyMaterialized(s, "inbound", "tproxy", {
        tabs: ["basic"],
        fields: [
          { name: "nft_rules", type: "bool", tab: "basic", exclusive: true },
        ],
      });
      const oo = findOpt(opts, "nft_rules");
      expect(oo?._exclusiveOwner("tpB")).toBe("tpA");
      uci.sections = origSections;
    });
  });
});
