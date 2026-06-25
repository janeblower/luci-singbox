import { describe, expect, it } from "bun:test";
import { resolve } from "node:path";
import { loadLuciModule } from "../helpers/luci.ts";

// Host-side unit coverage for the AWG-WARP plugin form module.
// The browser test (tests/browser/65-plugin-awg-warp.mjs) graceful-skips in
// CI because the plugin is not installed in the browser container, leaving
// renderOutboundForm with no executed coverage.  This test provides real
// runtime coverage of the form logic without a headless browser.

const TAB_JS = resolve(
  import.meta.dir,
  "../../plugins/awg_warp/htdocs/luci-static/resources/view/singbox-ui/plugins/awg_warp/tab.js",
);

// --- Option stub: supports all chained property assignments / method calls
// that tab.js makes, without throwing.
type OptionStub = {
  _id: string;
  _TypeName: string;
  _dependsArgs: unknown[][];
  _values: [string, string][];
  modalonly: boolean | undefined;
  inputtitle: unknown;
  inputstyle: unknown;
  rows: unknown;
  optional: unknown;
  default: unknown;
  datatype: unknown;
  placeholder: unknown;
  description: unknown;
  write: unknown;
  onclick: unknown;
  depends(...args: unknown[]): OptionStub;
  value(v: string, label: string): OptionStub;
};

function makeOptionStub(TypeName: string, id: string): OptionStub {
  const stub: OptionStub = {
    _id: id,
    _TypeName: TypeName,
    _dependsArgs: [],
    _values: [],
    modalonly: undefined,
    inputtitle: undefined,
    inputstyle: undefined,
    rows: undefined,
    optional: undefined,
    default: undefined,
    datatype: undefined,
    placeholder: undefined,
    description: undefined,
    write: undefined,
    onclick: undefined,
    depends(...args: unknown[]) {
      stub._dependsArgs.push(args);
      return stub;
    },
    value(v: string, label: string) {
      stub._values.push([v, label]);
      return stub;
    },
  };
  return stub;
}

// --- Mock CBI section: records each .taboption() call ---
type AddedEntry = { id: string; TypeName: string; stub: OptionStub };

function makeMockSection() {
  const added: AddedEntry[] = [];
  return {
    _added: added,
    taboption(
      _tab: string,
      TypeCtor: { _name?: string },
      id: string,
      _label: unknown,
    ): OptionStub {
      const TypeName = TypeCtor?._name ?? String(TypeCtor);
      const stub = makeOptionStub(TypeName, id);
      added.push({ id, TypeName, stub });
      return stub;
    },
  };
}

// --- Form type constructors: carry a _name tag for assertion ---
function makeFormType(name: string) {
  const ctor = () => {};
  (ctor as unknown as { _name: string })._name = name;
  return ctor as unknown as { _name: string };
}

// --- Load tab.js with mocked LuCI dependencies ---
const { exports: mod } = loadLuciModule(TAB_JS, {
  _: (s: unknown) => s,
  E: (tag: unknown, _attrs?: unknown, ..._children: unknown[]) => ({ tag }),
  form: {
    Button: makeFormType("Button"),
    TextValue: makeFormType("TextValue"),
    ListValue: makeFormType("ListValue"),
    Flag: makeFormType("Flag"),
    Value: makeFormType("Value"),
  },
  rpc: {
    declare: (_cfg: unknown) => () => Promise.resolve({ status: "ok" }),
  },
  ui: {
    addNotification: () => {},
  },
});

// ---------------------------------------------------------------------------
describe("awg_warp plugin tab.js", () => {
  describe("outboundTypes()", () => {
    it("returns a single entry for awg_warp", () => {
      const types: [string, unknown][] = mod.outboundTypes();
      expect(types).toHaveLength(1);
      expect(types[0][0]).toBe("awg_warp");
    });

    it("label is a non-empty string (via mock _() passthrough)", () => {
      const types: [string, unknown][] = mod.outboundTypes();
      expect(typeof types[0][1]).toBe("string");
      expect((types[0][1] as string).length).toBeGreaterThan(0);
    });
  });

  describe("renderOutboundForm()", () => {
    // Run the form builder once; all assertions share the resulting section.
    const section = makeMockSection();
    mod.renderOutboundForm("awg_warp", "warp_x", { section, map: {} });

    const addedIds = section._added.map((e) => e.id);

    // Helper: look up a specific entry by id.
    function get(id: string): AddedEntry {
      const e = section._added.find((x) => x.id === id);
      if (!e) throw new Error(`option '${id}' not found in section`);
      return e;
    }

    it("adds exactly 7 controls", () => {
      expect(section._added).toHaveLength(7);
    });

    it("adds _install control", () => {
      expect(addedIds).toContain("_install");
    });
    it("adds _register control", () => {
      expect(addedIds).toContain("_register");
    });
    it("adds warp_paste control", () => {
      expect(addedIds).toContain("warp_paste");
    });
    it("adds awg_mimic control", () => {
      expect(addedIds).toContain("awg_mimic");
    });
    it("adds _regen control", () => {
      expect(addedIds).toContain("_regen");
    });
    it("adds ipv6_enabled control", () => {
      expect(addedIds).toContain("ipv6_enabled");
    });
    it("adds mtu_override control", () => {
      expect(addedIds).toContain("mtu_override");
    });

    it("_install uses form.Button", () => {
      expect(get("_install").TypeName).toBe("Button");
    });
    it("_register uses form.Button", () => {
      expect(get("_register").TypeName).toBe("Button");
    });
    it("warp_paste uses form.TextValue", () => {
      expect(get("warp_paste").TypeName).toBe("TextValue");
    });
    it("awg_mimic uses form.ListValue", () => {
      expect(get("awg_mimic").TypeName).toBe("ListValue");
    });
    it("_regen uses form.Button", () => {
      expect(get("_regen").TypeName).toBe("Button");
    });
    it("ipv6_enabled uses form.Flag", () => {
      expect(get("ipv6_enabled").TypeName).toBe("Flag");
    });
    it("mtu_override uses form.Value", () => {
      expect(get("mtu_override").TypeName).toBe("Value");
    });

    it("awg_mimic has the expected mimic values", () => {
      const values = get("awg_mimic").stub._values.map((v) => v[0]);
      expect(values).toEqual([
        "auto",
        "quic",
        "dns",
        "stun",
        "dtls",
        "sip",
        "tls",
        "static",
      ]);
    });

    it("ipv6_enabled has default '0'", () => {
      expect(get("ipv6_enabled").stub.default).toBe("0");
    });

    it("mtu_override is optional with datatype uinteger", () => {
      expect(get("mtu_override").stub.optional).toBe(true);
      expect(get("mtu_override").stub.datatype).toBe("uinteger");
    });

    it("all controls depend on type=awg_warp", () => {
      for (const entry of section._added) {
        const hasAwgDep = entry.stub._dependsArgs.some(
          (args) => args[0] === "type" && args[1] === "awg_warp",
        );
        expect(hasAwgDep).toBe(true);
      }
    });

    it("warp_paste has a write() function", () => {
      expect(typeof get("warp_paste").stub.write).toBe("function");
    });

    it("_install has an onclick handler", () => {
      expect(typeof get("_install").stub.onclick).toBe("function");
    });
    it("_register has an onclick handler", () => {
      expect(typeof get("_register").stub.onclick).toBe("function");
    });
    it("_regen has an onclick handler", () => {
      expect(typeof get("_regen").stub.onclick).toBe("function");
    });

    it("all controls have modalonly=true", () => {
      for (const entry of section._added) {
        expect(entry.stub.modalonly).toBe(true);
      }
    });
  });
});
