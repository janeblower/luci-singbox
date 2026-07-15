import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { loadLuciModule } from "../helpers/luci";

// Two-step outbound type picker: `_kind` (Manual / Groups / Subscription) filters
// the `type` dropdown down to that mode's members.
//
// The load-bearing constraint: `type` stays the ONE UCI discriminator (every
// descriptor depends() arm keys off it) and must NOT carry a depends() of its
// own — LuCI would then treat it as inactive and parse() would DELETE type from
// UCI. So `_kind` is session-only (write/remove are no-ops, cfgvalue derives from
// type) and hides <option>s rather than gating the option.
//
// `hidden` is ours; `disabled` belongs to applyVersionGate. Clearing it here
// would silently re-offer a type the running sing-box rejects.

const VIEW_ROOT = resolve(
  import.meta.dirname,
  "../../luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui",
);

// biome-ignore lint/suspicious/noExplicitAny: CBI options are duck-typed bags.
type Opt = Record<string, any>;

interface UciSection {
  ".name": string;
  [k: string]: unknown;
}

// --- DOM stand-ins: only what the renderWidget wrappers actually touch. -----
class OptionEl {
  hidden = false;
  disabled = false;
  constructor(public value: string) {}
}

class RowEl {
  style = { display: "" };
}

class SelectEl {
  tagName = "SELECT";
  value = "";
  options: OptionEl[];
  private listeners: Record<string, (() => void)[]> = {};

  constructor(
    values: string[],
    private readonly row: RowEl,
  ) {
    this.options = values.map((v) => new OptionEl(v));
  }
  querySelector() {
    return null;
  }
  closest(sel: string) {
    return sel === ".cbi-value" ? this.row : null;
  }
  addEventListener(ev: string, fn: () => void) {
    const fns = this.listeners[ev] ?? [];
    fns.push(fn);
    this.listeners[ev] = fns;
  }
  dispatchEvent(ev: { type: string }) {
    for (const fn of this.listeners[ev.type] ?? []) fn();
    return true;
  }
  visible(): string[] {
    return this.options.filter((o) => !o.hidden).map((o) => o.value);
  }
}

interface Registered {
  tab: string;
  name: string;
  opt: Opt;
}

// Mirrors the real dropdown closely enough: one type per kind, plus a stand-in
// for whatever applyVersionGate has already disabled.
const TYPE_VALUES = [
  "direct",
  "anytls",
  "vless",
  "selector",
  "urltest",
  "subscription",
];

const STATE: Record<string, UciSection> = {
  vless_out: { ".name": "vless_out", ".type": "outbound", type: "vless" },
  grp: { ".name": "grp", ".type": "outbound", type: "urltest" },
  sub: { ".name": "sub", ".type": "outbound", type: "subscription" },
  fresh: { ".name": "fresh", ".type": "outbound" },
};

// outbounds.js wraps renderWidget at BUILD time, so the stub widget has to be in
// place before buildOutboundsMap() runs — hence the factory map.
function loadOutbounds(widgets: Record<string, () => unknown> = {}) {
  const registered: Registered[] = [];

  function mkOpt(tab: string, name: string): Opt {
    const opt: Opt = {
      value() {},
      depends() {},
      renderWidget: () => widgets[name]?.() ?? null,
      parse: () => Promise.resolve(),
      write() {},
      remove() {},
      formvalue: () => "",
    };
    registered.push({ tab, name, opt });
    return opt;
  }

  const section = {
    sectiontype: "outbound",
    tabs: [] as { name: string }[],
    tab(name: string) {
      this.tabs.push({ name });
    },
    option: (_w: unknown, name: string) => mkOpt("", name),
    taboption: (tab: string, _w: unknown, name: string) => mkOpt(tab, name),
    renderSectionAdd: () => null,
    handleAdd() {},
    renderRowActions: () => null,
  };

  const uci = {
    get: (_cfg: string, sid: string, opt?: string) =>
      opt === undefined ? (STATE[sid] ?? null) : (STATE[sid]?.[opt] ?? null),
    set: () => {},
    add: () => {},
    rename: () => {},
    sections: (_cfg: string, stype?: string) =>
      Object.values(STATE).filter((s) => !stype || s[".type"] === stype),
  };

  const mod = loadLuciModule(resolve(VIEW_ROOT, "tabs/outbounds.js"), {
    _: (s: unknown) => s,
    form: {
      Map: class {
        section() {
          return section;
        }
      },
      GridSection: "GridSection",
      Value: "Value",
      Flag: "Flag",
      ListValue: "ListValue",
      Button: "Button",
      DummyValue: "DummyValue",
    },
    uci,
    ui: {
      createHandlerFn: () => () => {},
      showModal: () => {},
      hideModal: () => {},
    },
    rpc: {},
    widgets: {},
    SbCommon: {
      addRenameField: () => {},
      applyVersionGate: () => {},
      lockBuiltinRow: () => {},
    },
    SbValidators: { url: () => true },
    descriptor_form: { applyMaterialized: () => {} },
    SbImpOutbound: {},
    SbJsonEditor: { addJsonButtons: () => {} },
    SbTabInbounds: { openJsonImportModal: () => {} },
    SbViewState: {
      getSchema: () => ({}),
      getCoreVersion: () => "",
      getCompatOnly: () => false,
    },
    Event: class {
      constructor(public type: string) {}
    },
    // The module defers the row-hide by one tick because CBI has not wrapped the
    // widget in its .cbi-value row yet at renderWidget time; run it inline here.
    window: { setTimeout: (fn: () => void) => fn() },
    Uint8Array,
    Math,
  }).exports as {
    kindOfType: (t: string) => string;
    buildOutboundsMap: () => unknown;
  };
  mod.buildOutboundsMap();

  return {
    mod,
    find: (name: string) =>
      registered.find((r) => r.name === name) as Registered,
  };
}

// Build the two selects, run the module, then render both options.
function setup(cfgvalue: string, gatedDisabled: string[] = []) {
  const typeRow = new RowEl();
  const typeSel = new SelectEl(TYPE_VALUES, typeRow);
  typeSel.value = cfgvalue;
  for (const d of gatedDisabled) {
    const o = typeSel.options.find((x) => x.value === d);
    if (o) o.disabled = true;
  }
  const kindSel = new SelectEl(
    ["manual", "group", "subscription"],
    new RowEl(),
  );

  const { find } = loadOutbounds({
    type: () => typeSel,
    _kind: () => kindSel,
  });
  find("type").opt.renderWidget("sid", 0, cfgvalue);
  find("_kind").opt.renderWidget("sid", 0, "");

  return { typeSel, typeRow, kindSel };
}

function switchKind(kindSel: SelectEl, kind: string) {
  kindSel.value = kind;
  kindSel.dispatchEvent({ type: "change" });
}

describe("kindOfType", () => {
  const { mod } = loadOutbounds();

  it("derives the mode from the type; plugin types fall through to manual", () => {
    expect(mod.kindOfType("subscription")).toBe("subscription");
    expect(mod.kindOfType("selector")).toBe("group");
    expect(mod.kindOfType("urltest")).toBe("group");
    expect(mod.kindOfType("vless")).toBe("manual");
    expect(mod.kindOfType("direct")).toBe("manual");
    expect(mod.kindOfType("awg")).toBe("manual"); // a plugin-contributed type
    expect(mod.kindOfType("")).toBe("manual"); // a brand-new section
  });
});

describe("_kind option", () => {
  const { find } = loadOutbounds();
  const kind = find("_kind");

  it("lives in the basic tab and is modal-only", () => {
    expect(kind).toBeDefined();
    expect(kind.tab).toBe("basic");
    expect(kind.opt.modalonly).toBe(true);
  });

  it("never writes to UCI — two persisted discriminators could disagree", () => {
    expect(kind.opt.write("vless_out", "group")).toBeUndefined();
    expect(kind.opt.remove("vless_out")).toBeUndefined();
  });

  it("derives its value from the section's type", () => {
    expect(kind.opt.cfgvalue("vless_out")).toBe("manual");
    expect(kind.opt.cfgvalue("grp")).toBe("group");
    expect(kind.opt.cfgvalue("sub")).toBe("subscription");
    expect(kind.opt.cfgvalue("fresh")).toBe("manual");
  });
});

describe("type dropdown filtering", () => {
  it("shows only manual protocols for an existing vless outbound", () => {
    const { typeSel, typeRow } = setup("vless");
    expect(typeSel.visible()).toEqual(["direct", "anytls", "vless"]);
    expect(typeRow.style.display).toBe("");
  });

  it("shows only the two group types for an existing urltest group", () => {
    const { typeSel } = setup("urltest");
    expect(typeSel.visible()).toEqual(["selector", "urltest"]);
  });

  it("hides the whole Type row for a subscription, but keeps the option active", () => {
    const { typeSel, typeRow } = setup("subscription");
    expect(typeRow.style.display).toBe("none");
    // Still active, so type=subscription is written. A depends() here would make
    // LuCI treat the option as inactive and DELETE type from UCI instead.
    expect(typeSel.value).toBe("subscription");
  });

  it("switching the mode re-filters and resets the type to the first allowed one", () => {
    const { typeSel, kindSel } = setup("vless");
    switchKind(kindSel, "group");

    expect(typeSel.value).toBe("selector");
    expect(typeSel.visible()).toEqual(["selector", "urltest"]);
  });

  it("switching to subscription pins type=subscription and hides the row", () => {
    const { typeSel, typeRow, kindSel } = setup("vless");
    switchKind(kindSel, "subscription");

    expect(typeSel.value).toBe("subscription");
    expect(typeRow.style.display).toBe("none");
  });

  it("does not reset the type when the mode already matches it", () => {
    const { typeSel, kindSel } = setup("urltest");
    switchKind(kindSel, "group");
    // urltest is already a group type — the user's pick must survive.
    expect(typeSel.value).toBe("urltest");
  });

  it("skips a version-gated type when picking the first allowed one", () => {
    const { typeSel, kindSel } = setup("urltest", ["direct"]);
    switchKind(kindSel, "manual");

    expect(typeSel.value).toBe("anytls");
    const direct = typeSel.options.find((o) => o.value === "direct");
    // applyVersionGate owns `disabled`; the filter must neither clear it nor
    // hide the option (the user still sees WHY it is unavailable).
    expect(direct?.disabled).toBe(true);
    expect(direct?.hidden).toBe(false);
  });
});
