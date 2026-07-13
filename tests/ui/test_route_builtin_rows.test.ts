import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import vm from "node:vm";
import { describe, expect, it } from "vitest";

// Built-in rule-sets render as ordinary grid rows the user does not own:
//   * Edit / Delete are disabled (greyed), the drag handle is not;
//   * the row gets .sb-builtin-row so style.css can tint it;
//   * `enabled` stays a live per-row toggle — turning the ones you want on is
//     the entire point of shipping 25 of them;
//   * with singbox-ui.main.default_rulesets = 0 the rows are filtered out.
//
// builtinsOn() must agree with helpers.builtin_rulesets_on() in the backend
// (unset = ON). If the two drift, the grid shows rows the generated config does
// not contain, or hides rows it does.

const VIEW_ROOT = resolve(
  import.meta.dirname,
  "../../luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui",
);

interface UciSection {
  ".name": string;
  [k: string]: unknown;
}

interface RouteMod {
  isBuiltin: (sid: string) => boolean;
  builtinsOn: () => boolean;
  lockBuiltinRow: (s: GridStub, note: string) => void;
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
  filter?: (sid: string) => boolean;
  renderRowActions: (sid: string, label: string | null, tr: TrStub) => TdStub;
}

function load(state: Record<string, UciSection>) {
  const src = readFileSync(resolve(VIEW_ROOT, "tabs/route.js"), "utf8");
  const body = src
    .replace(/^'use strict';\s*/, "")
    .replace(/^'require [^']+';\s*/gm, "")
    .replace(
      /return L\.Class\.extend\((\{[\s\S]*\})\);?\s*$/,
      "__moduleExports = $1;",
    );

  const uci = {
    get: (_cfg: string, sid: string, opt?: string) =>
      opt === undefined ? (state[sid] ?? null) : (state[sid]?.[opt] ?? null),
    sections: (_cfg: string, stype?: string) =>
      Object.values(state).filter((s) => !stype || s[".type"] === stype),
  };

  const sandbox: Record<string, unknown> = {
    __moduleExports: null,
    _: (s: unknown) => s,
    L: { Class: { extend: (o: unknown) => o } },
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
    uci,
    SbCommon: { addRenameField: () => {}, applyVersionGate: () => {} },
    descriptor_form: { applyMaterialized: () => {} },
    SbViewState: { getSchema: () => ({}) },
    console,
  };
  vm.createContext(sandbox);
  vm.runInContext(`(function() {${body}})();`, sandbox, {
    filename: "route.js",
  });
  return sandbox.__moduleExports as RouteMod;
}

// The stock LuCI action cell: drag handle + Edit ("More…") + Delete.
function makeGrid(): GridStub & { lastTd?: TdStub } {
  const g: GridStub & { lastTd?: TdStub } = {
    renderRowActions() {
      const td = new TdStub([
        new BtnStub(["cbi-button", "drag-handle"]),
        new BtnStub(["cbi-button", "cbi-button-edit"]),
        new BtnStub(["cbi-button", "cbi-button-remove"]),
      ]);
      g.lastTd = td;
      return td;
    },
  };
  return g;
}

const STATE: Record<string, UciSection> = {
  main: { ".name": "main", ".type": "singbox-ui" },
  discord: { ".name": "discord", ".type": "ruleset", builtin: "1" },
  mine: { ".name": "mine", ".type": "ruleset" },
};

describe("builtin rule-set rows", () => {
  it("isBuiltin only fires on builtin='1'", () => {
    const r = load(STATE);
    expect(r.isBuiltin("discord")).toBe(true);
    expect(r.isBuiltin("mine")).toBe(false);
    expect(r.isBuiltin("nonexistent")).toBe(false);
  });

  it("builtinsOn treats an unset switch as ON (matches the backend)", () => {
    expect(load(STATE).builtinsOn()).toBe(true);
    expect(
      load({
        ...STATE,
        main: { ".name": "main", ".type": "singbox-ui", default_rulesets: "1" },
      }).builtinsOn(),
    ).toBe(true);
    expect(
      load({
        ...STATE,
        main: { ".name": "main", ".type": "singbox-ui", default_rulesets: "0" },
      }).builtinsOn(),
    ).toBe(false);
  });

  it("disables Edit/Delete but not the drag handle, and tints the row", () => {
    const r = load(STATE);
    const g = makeGrid();
    r.lockBuiltinRow(g, "locked");

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
    const r = load(STATE);
    const g = makeGrid();
    r.lockBuiltinRow(g, "locked");

    const tr = new TrStub();
    const td = g.renderRowActions("mine", "More…", tr);

    expect(tr.classes).toEqual([]);
    expect(td.buttons.every((b) => !b.disabled)).toBe(true);
  });

  it("filters builtin rows out when the master switch is off", () => {
    const on = load(STATE);
    const gOn = makeGrid();
    on.lockBuiltinRow(gOn, "locked");
    expect(gOn.filter?.("discord")).toBe(true);
    expect(gOn.filter?.("mine")).toBe(true);

    const off = load({
      ...STATE,
      main: { ".name": "main", ".type": "singbox-ui", default_rulesets: "0" },
    });
    const gOff = makeGrid();
    off.lockBuiltinRow(gOff, "locked");
    expect(gOff.filter?.("discord")).toBe(false);
    expect(gOff.filter?.("mine")).toBe(true);
  });
});
