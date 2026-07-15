import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { loadLuciModule } from "../helpers/luci";

// Package-owned grid rows (`builtin '1'`): the 25 allow-domains rule-sets and
// the built-in `wan` outbound. They render as ordinary rows the user does not
// own:
//   * Edit / Delete are disabled (greyed), the drag handle is not;
//   * the row gets .sb-builtin-row so style.css can tint it;
//   * `enabled` stays a live per-row toggle — turning the rule-sets you want on
//     is the entire point of shipping 25 of them;
//   * an optional hide predicate filters the rows away entirely. The rule-sets
//     pass one (main.default_rulesets); the wan outbound does not — it has no
//     master switch, generate.uc just stops emitting it once nothing references
//     it.
//
// route.js builtinsOn() must agree with helpers.builtin_rulesets_on() in the
// backend (unset = ON). If the two drift, the grid shows rows the generated
// config does not contain, or hides rows it does.

const VIEW_ROOT = resolve(
  import.meta.dirname,
  "../../luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui",
);

interface UciSection {
  ".name": string;
  [k: string]: unknown;
}

// A <button> stand-in: only the bits lockBuiltinRow touches.
class BtnStub {
  disabled = false;
  title = "";
  classList: { contains: (c: string) => boolean };
  constructor(private readonly cls: string[]) {
    this.classList = { contains: (c: string) => this.cls.includes(c) };
  }
}

class TdStub {
  // LuCI does `trEl.appendChild(this.renderRowActions(...))`, so the row becomes
  // this cell's parent one tick after we hand it back. That is the only handle on
  // the row that works across LuCI versions.
  parentNode: TrStub | null = null;
  constructor(readonly buttons: BtnStub[]) {}
  querySelectorAll(sel: string): BtnStub[] {
    return sel === "button" ? this.buttons : [];
  }
}

class TrStub {
  readonly classes: string[] = [];
  classList = { add: (c: string) => this.classes.push(c) };
}

interface GridStub {
  uciconfig?: string;
  filter?: (sid: string) => boolean;
  // trEl is OPTIONAL on purpose: the LuCI shipped in OpenWrt 25.12 does not pass
  // it (its GridSection override drops every argument but section_id).
  renderRowActions: (sid: string, label?: string | null, tr?: TrStub) => TdStub;
}

function mkUci(state: Record<string, UciSection>) {
  return {
    get: (_cfg: string, sid: string, opt?: string) =>
      opt === undefined ? (state[sid] ?? null) : (state[sid]?.[opt] ?? null),
    set: () => {},
    rename: () => {},
    sections: (_cfg: string, stype?: string) =>
      Object.values(state).filter((s) => !stype || s[".type"] === stype),
  };
}

function evalModule(
  file: string,
  extra: Record<string, unknown>,
): Record<string, unknown> {
  return loadLuciModule(resolve(VIEW_ROOT, file), {
    _: (s: unknown) => s,
    form: {
      Map: class {
        section() {
          return {};
        }
      },
      GridSection: "GridSection",
      NamedSection: "NamedSection",
      Value: "Value",
      Flag: "Flag",
      ListValue: "ListValue",
      DummyValue: "DummyValue",
    },
    ui: {},
    SbRpc: {},
    E: () => ({}),
    ...extra,
  }).exports as Record<string, unknown>;
}

interface CommonMod {
  isBuiltin: (sid: string) => boolean;
  lockBuiltinRow: (s: GridStub, note: string, hideFn?: () => boolean) => void;
}

// The tint is deferred by a tick (the row is only the cell's parent AFTER
// renderRowActions returns), so the test drives the clock by hand.
class Clock {
  private readonly deferred: (() => void)[] = [];
  get seams() {
    return {
      window: { setTimeout: (fn: () => void) => this.deferred.push(fn) },
    };
  }
  tick(): void {
    for (const fn of this.deferred.splice(0)) fn();
  }
}

function loadCommon(
  state: Record<string, UciSection>,
  clock = new Clock(),
): CommonMod & { clock: Clock } {
  const mod = evalModule("lib/common.js", {
    uci: mkUci(state),
    ...clock.seams,
  }) as unknown as CommonMod;
  return Object.assign(mod, { clock });
}

// route.js's builtinsOn IS SbCommon.builtinRulesetsOn — one predicate, mirroring
// the backend's one helpers.builtin_rulesets_on(). So SbCommon here is the REAL
// common.js over the same UCI state, not a stub: stubbing it would let the two
// drift apart and still pass, which is the whole failure mode being guarded.
function loadRoute(state: Record<string, UciSection>): {
  builtinsOn: () => boolean;
} {
  const uci = mkUci(state);
  const SbCommon = evalModule("lib/common.js", {
    uci,
    window: { setTimeout: () => {} },
  });
  return evalModule("tabs/route.js", {
    uci,
    SbCommon,
    descriptor_form: { applyMaterialized: () => {} },
    SbViewState: { getSchema: () => ({}), getCoreVersion: () => "" },
  }) as unknown as { builtinsOn: () => boolean };
}

// The stock LuCI action cell: drag handle + Edit ("More…") + Delete.
function makeGrid(): GridStub {
  return {
    renderRowActions() {
      return new TdStub([
        new BtnStub(["cbi-button", "drag-handle"]),
        new BtnStub(["cbi-button", "cbi-button-edit"]),
        new BtnStub(["cbi-button", "cbi-button-remove"]),
      ]);
    },
  };
}

const STATE: Record<string, UciSection> = {
  main: { ".name": "main", ".type": "singbox-ui" },
  discord: { ".name": "discord", ".type": "ruleset", builtin: "1" },
  mine: { ".name": "mine", ".type": "ruleset" },
  wan: { ".name": "wan", ".type": "outbound", builtin: "1" },
  vless_out: { ".name": "vless_out", ".type": "outbound" },
};

const OFF: Record<string, UciSection> = {
  ...STATE,
  main: { ".name": "main", ".type": "singbox-ui", default_rulesets: "0" },
};

describe("builtin rows", () => {
  it("isBuiltin only fires on builtin='1'", () => {
    const c = loadCommon(STATE);
    expect(c.isBuiltin("discord")).toBe(true);
    expect(c.isBuiltin("wan")).toBe(true);
    expect(c.isBuiltin("mine")).toBe(false);
    expect(c.isBuiltin("vless_out")).toBe(false);
    expect(c.isBuiltin("nonexistent")).toBe(false);
  });

  it("disables Edit/Delete but not the drag handle, and tints the row", () => {
    const c = loadCommon(STATE);
    const g = makeGrid();
    c.lockBuiltinRow(g, "locked");

    const tr = new TrStub();
    const td = g.renderRowActions("discord", "More…", tr);

    expect(tr.classes).toContain("sb-builtin-row");
    const [drag, edit, del] = td.buttons;
    expect(drag.disabled).toBe(false);
    expect(edit.disabled).toBe(true);
    expect(del.disabled).toBe(true);
    expect(edit.title).toBe("locked");
  });

  it("leaves a user-owned row completely alone", () => {
    const c = loadCommon(STATE);
    const g = makeGrid();
    c.lockBuiltinRow(g, "locked");

    const tr = new TrStub();
    const td = g.renderRowActions("mine", "More…", tr);

    expect(tr.classes).toEqual([]);
    expect(td.buttons.every((b) => !b.disabled)).toBe(true);
  });

  it("tints the row even when LuCI does not pass the <tr> (the real-router path)", () => {
    // The LuCI in OpenWrt 25.12 calls renderRowActions(section_id) — its
    // GridSection override drops more_label AND the row — so trEl is undefined
    // and relying on it meant the buttons greyed out but the row never tinted.
    // Looking the row up in the document would not have worked either: LuCI
    // assembles the whole table in memory and inserts it later. The cell's
    // parentNode is the one handle that holds across versions.
    const clock = new Clock();
    const c = loadCommon(STATE, clock);
    const g = makeGrid();
    c.lockBuiltinRow(g, "locked");

    // NOTE: no second or third argument — exactly how the shipped LuCI calls it.
    const td = g.renderRowActions("discord");

    // The buttons are disabled synchronously...
    expect(td.buttons[1].disabled).toBe(true);
    expect(td.buttons[2].disabled).toBe(true);

    // ...and the tint lands a tick later, once LuCI has appended the cell.
    const tr = new TrStub();
    td.parentNode = tr;
    expect(tr.classes).toEqual([]);
    clock.tick();
    expect(tr.classes).toContain("sb-builtin-row");
  });

  it("does not tint a user-owned row through the fallback either", () => {
    const clock = new Clock();
    const c = loadCommon(STATE, clock);
    const g = makeGrid();
    c.lockBuiltinRow(g, "locked");

    const td = g.renderRowActions("mine");
    const tr = new TrStub();
    td.parentNode = tr;
    clock.tick();
    expect(tr.classes).toEqual([]);
  });

  it("installs no filter when no hide predicate is given (the wan outbound)", () => {
    const c = loadCommon(STATE);
    const g = makeGrid();
    c.lockBuiltinRow(g, "locked");
    // The built-in outbound must stay visible whatever the rule-set switch says.
    expect(g.filter).toBeUndefined();
  });

  it("filters builtin rows out when the hide predicate says so", () => {
    const c = loadCommon(OFF);
    const g = makeGrid();
    c.lockBuiltinRow(g, "locked", () => true);
    expect(g.filter?.("discord")).toBe(false);
    expect(g.filter?.("mine")).toBe(true);
  });
});

describe("route.js builtinsOn", () => {
  it("treats an unset switch as ON (matches helpers.builtin_rulesets_on)", () => {
    expect(loadRoute(STATE).builtinsOn()).toBe(true);
    expect(
      loadRoute({
        ...STATE,
        main: { ".name": "main", ".type": "singbox-ui", default_rulesets: "1" },
      }).builtinsOn(),
    ).toBe(true);
    expect(loadRoute(OFF).builtinsOn()).toBe(false);
  });
});
