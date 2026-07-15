import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { formStub, validatorsStub } from "../helpers/form-stub";
import { loadLuciModule } from "../helpers/luci";

// tests/test_audit_2_4.sh — regression for audit 2.4.
// Shared (tab,name) fields collapse to ONE LuCI widget; explicit ui_label
// beats a name-derived one regardless of registration order.

const VIEW_ROOT = resolve(
  import.meta.dirname,
  "../../luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui",
);
const DESCRIPTOR_FORM_JS = resolve(VIEW_ROOT, "lib/descriptor_form.js");

// ---- load descriptor_form --------------------------------------------------

function loadDF() {
  return loadLuciModule(DESCRIPTOR_FORM_JS, {
    _: (s: unknown) => s,
    form: formStub,
    ui: {},
    validators: validatorsStub,
    SbViewState: {
      getCoreVersion: () => "",
      getCompatOnly: () => false,
    },
    SbCommon: { compareVersions: () => 0 },
  }).exports;
}

// ---- section mock ----------------------------------------------------------

function makeSection() {
  const opts: any[] = [];
  const s = {
    tab: () => {},
    taboption: (
      _tab: unknown,
      _widget: unknown,
      name: string,
      title: string,
    ) => {
      const o: any = { _name: name, title, option: name };
      o.depends = () => o;
      o.value = () => o;
      opts.push(o);
      return o;
    },
  };
  return { s, opts };
}

// ---- descriptors -----------------------------------------------------------

const derived = {
  tabs: ["basic"],
  fields: [{ name: "server_password", type: "string", tab: "basic" }],
};
const explicit = {
  tabs: ["basic"],
  fields: [
    {
      name: "server_password",
      type: "string",
      tab: "basic",
      ui_label: "Password (single user)",
    },
  ],
};

// ---- tests -----------------------------------------------------------------

describe("audit 2.4 — shared-field label is order-independent", () => {
  it("derived first, explicit second → explicit ui_label wins", () => {
    const DF = loadDF();
    const { s, opts } = makeSection();
    DF.applyMaterialized(s, "inbound", "shadowsocks", derived);
    DF.applyMaterialized(s, "inbound", "hysteria2", explicit);
    const deduped = opts.filter((x) => x._name === "server_password");
    expect(deduped.length).toBe(1);
    expect(deduped[0].title).toBe("Password (single user)");
  });

  it("explicit first, derived second → explicit ui_label not clobbered", () => {
    const DF = loadDF();
    const { s, opts } = makeSection();
    DF.applyMaterialized(s, "inbound", "hysteria2", explicit);
    DF.applyMaterialized(s, "inbound", "shadowsocks", derived);
    const o = opts.find((x) => x._name === "server_password");
    expect(o?.title).toBe("Password (single user)");
  });

  it("both derived → name-cased fallback label", () => {
    const DF = loadDF();
    const { s, opts } = makeSection();
    DF.applyMaterialized(s, "inbound", "shadowsocks", derived);
    DF.applyMaterialized(s, "inbound", "trojan", derived);
    const o = opts.find((x) => x._name === "server_password");
    expect(o?.title).toBe("Server password");
  });
});
