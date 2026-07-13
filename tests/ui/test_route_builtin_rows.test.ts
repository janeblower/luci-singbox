import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import vm from "node:vm";
import { describe, expect, it } from "vitest";

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
  const src = readFileSync(resolve(VIEW_ROOT, file), "utf8");
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
    window: {},
    document: {},
    console,
    ...extra,
  };
  vm.createContext(sandbox);
  vm.runInContext(`(function() {${body}})();`, sandbox, { filename: file });
  return sandbox.__moduleExports as Record<string, unknown>;
}

interface CommonMod {
  isBuiltin: (sid: string) => boolean;
  lockBuiltinRow: (s: GridStub, note: string, hideFn?: () => boolean) => void;
}

function loadCommon(state: Record<string, UciSection>): CommonMod {
  return evalModule("lib/common.js", {
    uci: mkUci(state),
  }) as unknown as CommonMod;
}

function loadRoute(state: Record<string, UciSection>): {
  builtinsOn: () => boolean;
} {
  return evalModule("tabs/route.js", {
    uci: mkUci(state),
    SbCommon: {
      addRenameField: () => {},
      applyVersionGate: () => {},
      lockBuiltinRow: () => {},
      loadOutboundList: () => {},
    },
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
