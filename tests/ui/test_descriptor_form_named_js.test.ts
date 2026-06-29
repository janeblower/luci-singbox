import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import vm from "node:vm";
import { describe, expect, it } from "vitest";

// tests/test_descriptor_form_named_js.sh — port of applyMaterializedNamed tests.

const VIEW_ROOT = resolve(
  import.meta.dirname,
  "../../luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui",
);
const DESCRIPTOR_FORM_JS = resolve(VIEW_ROOT, "lib/descriptor_form.js");

function FakeOpt(this: any, n: string) {
  this.option = n;
  this.deps = [] as unknown[];
  this.readonly = false;
  this.title = n;
}
FakeOpt.prototype.depends = function (this: any, d: unknown) {
  this.deps.push(d);
};
FakeOpt.prototype.value = () => {};

const form = {
  Flag: FakeOpt,
  Value: FakeOpt,
  ListValue: FakeOpt,
  DynamicList: FakeOpt,
};
const uci = { sections: () => [] };
const network = {};
const validators = {};
const SbViewState = { getCoreVersion: () => "", getCompatOnly: () => false };
const SbCommon = { compareVersions: () => 0 };

function loadDescriptorFormNamed() {
  const src = readFileSync(DESCRIPTOR_FORM_JS, "utf8");
  // Shell test uses: .replace(/return L\.Class\.extend\(/, 'return (')
  // then: new Function('form','ui','uci','network','validators','SbViewState','SbCommon', body)
  // We replicate with vm + same replacement
  const body = src
    .replace(/^'use strict';\s*/, "")
    .replace(/'require [^']*';\s*/g, "")
    .replace(/return L\.Class\.extend\(/, "return (");

  const sandbox: Record<string, unknown> = {
    _: (s: unknown) => s,
    E: () => ({}),
    form,
    ui: {},
    uci,
    network,
    validators,
    SbViewState,
    SbCommon,
    L: { Class: { extend: (o: unknown) => o } },
    console,
  };
  vm.createContext(sandbox);
  // Wrap in a function that takes the params and returns the module object
  const wrappedBody = `(function(form,ui,uci,network,validators,SbViewState,SbCommon){ ${body} })(form,ui,uci,network,validators,SbViewState,SbCommon)`;
  const result = vm.runInContext(wrappedBody, sandbox, {
    filename: "descriptor_form.js",
  });
  return result;
}

const mod = loadDescriptorFormNamed();

describe("descriptor_form.js — applyMaterializedNamed", () => {
  it("exports applyMaterializedNamed", () => {
    expect(typeof mod?.applyMaterializedNamed).toBe("function");
  });

  describe("clash_api singleton rendering", () => {
    const section: any = {
      _opts: {},
      option(W: any, name: string, label: string) {
        const o = new W(name);
        o.title = label;
        this._opts[name] = o;
        return o;
      },
    };

    const mat = {
      sing_box_type: "clash_api",
      tabs: ["basic"],
      shared: {},
      fields: [
        { name: "secret", type: "string", tab: "basic", secret: true },
        { name: "listen", type: "string", tab: "basic", default: "127.0.0.1" },
        {
          name: "mode",
          type: "enum",
          tab: "basic",
          values: ["", "rule", "global"],
        },
        // advanced + parent_enabled: must yield ONE compound depends arm gating on
        // BOTH the advanced toggle AND the parent flag.
        {
          name: "adv1",
          type: "string",
          tab: "basic",
          advanced: true,
          parent_enabled: "enabled",
        },
      ],
    };

    mod.applyMaterializedNamed(section, "clash_api", "clash_api", mat);

    it("creates secret field", () => {
      expect(section._opts.secret).not.toBeUndefined();
    });

    it("creates listen field", () => {
      expect(section._opts.listen).not.toBeUndefined();
    });

    it("creates mode field", () => {
      expect(section._opts.mode).not.toBeUndefined();
    });

    it("applies default to listen field", () => {
      expect(section._opts.listen.default).toBe("127.0.0.1");
    });

    it("adv1 has exactly one depends arm", () => {
      const adv = section._opts.adv1;
      expect(adv).not.toBeUndefined();
      expect(adv.deps.length).toBe(1);
    });

    it("adv1 depends arm gates on BOTH _show_advanced_basic and parent_enabled", () => {
      const adv = section._opts.adv1;
      const d = adv.deps[0] as Record<string, string>;
      expect(d._show_advanced_basic).toBe("1");
      expect(d.enabled).toBe("1");
    });
  });
});
