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

// The real protocol schema for the two fields that claim the "transparent"
// group. Their `default`s are the load-bearing part: descriptor_form resolves an
// UNSET flag against its own descriptor default, so nft_rules (default 1, no
// json_key) is ON when unset and auto_route (default 0 — commit 61534499, LuCI's
// parse() deletes an option equal to its default) is OFF when unset.
const INBOUND_SCHEMA = {
  tproxy: {
    fields: [
      {
        name: "nft_rules",
        type: "bool",
        tab: "basic",
        default: 1,
        exclusive: "transparent",
      },
    ],
  },
  tun: {
    fields: [
      {
        name: "auto_route",
        type: "bool",
        tab: "basic",
        default: 0,
        exclusive: "transparent",
      },
    ],
  },
};

const SbViewState: any = {
  _ver: "",
  _compatOnly: false,
  _schema: {} as Record<string, unknown>,
  getSchema() {
    return SbViewState._schema;
  },
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

// ui.addNotification recorder — warnExclusiveConflicts() is what main.js calls
// at Apply time, and its return value is what holds the apply back.
const notifications = {
  _calls: [] as Array<{ msg: any; level: string }>,
  addNotification(_title: unknown, msg: unknown, level: string) {
    notifications._calls.push({ msg, level });
  },
};

// LuCI ships String.prototype.format; node does not, and descriptor_form uses it
// for the conflict message. The vm context is its own realm with its own String
// intrinsic, so the polyfill has to be evaluated INSIDE it. Minimal %s only.
const FORMAT_POLYFILL = `String.prototype.format = function () {
    var args = arguments, i = 0;
    return this.replace(/%s/g, function () { return String(args[i++]); });
};`;

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
    // LuCI ships String.prototype.format; node does not. Only the substitution
    // matters here, not LuCI's full format vocabulary.
    E: (_tag: string, _attrs: unknown, children: unknown) => ({ children }),
    form,
    ui: notifications,
    validators,
    uci,
    network,
    SbViewState,
    SbCommon,
    console,
    Promise,
  };
  vm.createContext(sandbox);
  vm.runInContext(FORMAT_POLYFILL, sandbox);
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

  // A dynamic source says WHERE the choices come from; the field's `type` says
  // which widget. `devices` used to force a DynamicList regardless, so a scalar
  // netdev field (bind_interface, dns/dhcp `interface`) rendered as a
  // multi-value list.
  //
  // bind_interface itself used to be dynamic:"interfaces" — a dropdown of
  // OpenWrt LOGICAL interfaces (wan/lan). sing-box passes the value to
  // SO_BINDTODEVICE, which wants an OS netdev, so every value that dropdown
  // offered bound the dialer to a device that does not exist. The source is now
  // `devices`, and dynamic:"interfaces" no longer exists at all.
  describe("2. dynamic:devices + type:string → Value (free-entry combobox of netdevs)", () => {
    const { s, opts } = makeSection();
    applyMaterialized(s, "outbound", "vless", {
      tabs: ["dial"],
      fields: [
        {
          name: "bind_interface",
          type: "string",
          tab: "dial",
          dynamic: "devices",
        },
      ],
    });
    const o = findOpt(opts, "bind_interface");

    it("widget is Value, not DynamicList (it is a scalar) and not a strict ListValue", () => {
      expect(o?._widget).toBe(form.Value);
    });

    it("load() resolves real netdev suggestions (async), not logical names", async () => {
      const r = o.load.call(o, "sid");
      expect(r && typeof r.then).toBe("function");
      await r;
      const k = keysOf(o);
      expect(k.indexOf("br-lan")).toBeGreaterThanOrEqual(0);
      expect(k.indexOf("eth0")).toBeGreaterThanOrEqual(0);
      // The logical names the old dropdown offered are gone.
      expect(k.indexOf("wan")).toBe(-1);
      expect(k.indexOf("lan")).toBe(-1);
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
        // default: 1 mirrors the real tproxy descriptor — and it is what makes
        // an UNSET nft_rules count as ON (the polarity comes from the field's
        // own default, not from a blanket rule).
        {
          name: "nft_rules",
          type: "bool",
          tab: "basic",
          default: 1,
          exclusive: true,
        },
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
          // default: 1 mirrors the real tproxy descriptor — and it is what makes
          // an UNSET nft_rules count as ON (the polarity comes from the field's
          // own default, not from a blanket rule).
          {
            name: "nft_rules",
            type: "bool",
            tab: "basic",
            default: 1,
            exclusive: true,
          },
        ],
      });
      const oo = findOpt(opts, "nft_rules");
      expect(oo?._exclusiveOwner("tpB")).toBe("tpA");
      uci.sections = origSections;
    });
  });

  // ------------------------------------------------------------------------
  // 10. exclusive: "<group>" — cross-protocol ownership of system routing.
  //
  // tproxy.nft_rules and tun.auto_route claim the SAME thing (system routing /
  // the firewall) under DIFFERENT names, and their polarity is OPPOSITE: unset
  // nft_rules means ON (default 1), unset auto_route means OFF (default 0).
  // A blanket `!== "0"` — what makeExclusive used to do for every field — lets a
  // tun that routes NOTHING claim the group, disable tproxy's checkbox and leave
  // the router with no interception at all. These cases fail if anyone reverts
  // to it.
  // ------------------------------------------------------------------------
  describe("10. exclusive group: cross-protocol (transparent)", () => {
    function withInbounds<T>(rows: any[], fn: (opts: any) => T): T {
      const origSections = uci.sections;
      SbViewState._schema = { inbound: INBOUND_SCHEMA };
      uci.sections = (config: string, type: string) =>
        config === "singbox-ui" && type === "inbound"
          ? rows
          : origSections(config, type);
      try {
        const { s, opts } = makeSection();
        applyMaterialized(s, "inbound", "tproxy", {
          tabs: ["basic"],
          fields: INBOUND_SCHEMA.tproxy.fields,
        });
        applyMaterialized(s, "inbound", "tun", {
          tabs: ["basic"],
          fields: INBOUND_SCHEMA.tun.fields,
        });
        return fn(opts);
      } finally {
        uci.sections = origSections;
        SbViewState._schema = {};
      }
    }

    it("a tun with UNSET auto_route does NOT claim the group (default 0 = OFF)", () => {
      // tun FIRST in UCI order: under a blanket `!== "0"` polarity it would win
      // the scan and own system routing while routing nothing.
      withInbounds(
        [
          { ".name": "tun_in", enabled: "1", protocol: "tun" },
          { ".name": "tproxy_in", enabled: "1", protocol: "tproxy" },
        ],
        (opts) => {
          const auto = findOpt(opts, "auto_route");
          const nft = findOpt(opts, "nft_rules");
          expect(auto._exclusiveOwner("tun_in")).toBe("tproxy_in");
          expect(nft._exclusiveOwner("tproxy_in")).toBe("tproxy_in");
          // and the tproxy owner keeps its flag
          uci._setCalls = [];
          nft.write("tproxy_in", "1");
          expect(uci._setCalls[0]?.[2]).toBe("1");
        },
      );
    });

    it("an UNSET nft_rules DOES claim the group (default 1 = ON), across protocols", () => {
      withInbounds(
        [
          { ".name": "tproxy_in", enabled: "1", protocol: "tproxy" },
          { ".name": "tun_in", enabled: "1", protocol: "tun", auto_route: "1" },
        ],
        (opts) => {
          const auto = findOpt(opts, "auto_route");
          expect(auto._exclusiveOwner("tun_in")).toBe("tproxy_in");
          uci._setCalls = [];
          auto.write("tun_in", "1");
          expect(uci._setCalls[0]?.[2]).toBe("0"); // loser forced off
        },
      );
    });

    it("tun owns it when tproxy's nft_rules is off", () => {
      withInbounds(
        [
          {
            ".name": "tproxy_in",
            enabled: "1",
            protocol: "tproxy",
            nft_rules: "0",
          },
          { ".name": "tun_in", enabled: "1", protocol: "tun", auto_route: "1" },
        ],
        (opts) => {
          const nft = findOpt(opts, "nft_rules");
          expect(nft._exclusiveOwner("tproxy_in")).toBe("tun_in");
          uci._setCalls = [];
          nft.write("tproxy_in", "1");
          expect(uci._setCalls[0]?.[2]).toBe("0");
        },
      );
    });

    it("a disabled section never claims", () => {
      withInbounds(
        [
          { ".name": "tproxy_in", enabled: "0", protocol: "tproxy" },
          { ".name": "tun_in", enabled: "1", protocol: "tun", auto_route: "1" },
        ],
        (opts) => {
          const auto = findOpt(opts, "auto_route");
          expect(auto._exclusiveOwner("tun_in")).toBe("tun_in");
        },
      );
    });

    it("exclusiveConflicts names both claimants and their fields", () => {
      withInbounds(
        [
          {
            ".name": "tproxy_in",
            enabled: "1",
            protocol: "tproxy",
            nft_rules: "1",
          },
          { ".name": "tun_in", enabled: "1", protocol: "tun", auto_route: "1" },
        ],
        () => {
          expect(DF.exclusiveConflicts("inbound")).toEqual([
            {
              group: "transparent",
              claimants: [
                { section: "tproxy_in", field: "nft_rules" },
                { section: "tun_in", field: "auto_route" },
              ],
            },
          ]);
        },
      );
    });

    it("warnExclusiveConflicts notifies and holds the apply back", () => {
      withInbounds(
        [
          {
            ".name": "tproxy_in",
            enabled: "1",
            protocol: "tproxy",
            nft_rules: "1",
          },
          { ".name": "tun_in", enabled: "1", protocol: "tun", auto_route: "1" },
        ],
        () => {
          notifications._calls = [];
          expect(DF.warnExclusiveConflicts("inbound")).toBe(true);
          expect(notifications._calls.length).toBe(1);
          expect(notifications._calls[0].level).toBe("error");
          // names BOTH inbounds and the field each claims with
          const msg = String(notifications._calls[0].msg.children[0]);
          expect(msg).toContain('"tproxy_in" (nft_rules)');
          expect(msg).toContain('"tun_in" (auto_route)');
        },
      );
    });

    it("warnExclusiveConflicts stays quiet — and lets Apply run — with one claimant", () => {
      withInbounds(
        [
          { ".name": "tproxy_in", enabled: "1", protocol: "tproxy" },
          { ".name": "tun_in", enabled: "1", protocol: "tun" },
        ],
        () => {
          notifications._calls = [];
          expect(DF.warnExclusiveConflicts("inbound")).toBe(false);
          expect(notifications._calls.length).toBe(0);
        },
      );
    });

    it("exclusiveConflicts is empty when only one section claims", () => {
      withInbounds(
        [
          { ".name": "tproxy_in", enabled: "1", protocol: "tproxy" },
          { ".name": "tun_in", enabled: "1", protocol: "tun" },
        ],
        () => {
          expect(DF.exclusiveConflicts("inbound")).toEqual([]);
        },
      );
    });
  });
});
