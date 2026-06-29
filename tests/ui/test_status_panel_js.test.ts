import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import vm from "node:vm";
import { describe, expect, it } from "vitest";

// tests/test_status_panel_js.sh — asserts renderStatusPanel handles RPC failure
// (S2-1): a rejected callStatus() must not reject the returned promise.

// status-panel.js uses a custom E() with more DOM features than loadLuciModule's
// default sandbox, so we build the sandbox manually (mirroring the original .sh).

const STATUS_PANEL_JS = resolve(
  import.meta.dirname,
  "../../luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/widgets/status-panel.js",
);

function makeEl(tag: string) {
  const el: any = {
    tag,
    _t: "",
    children: [] as any[],
    appendChild(x: any) {
      if (x) this.children.push(x);
      return x;
    },
    set innerHTML(v: string) {
      if (v === "") this.children = [];
    },
    get innerHTML() {
      return "";
    },
    get textContent(): string {
      let t = this._t;
      for (const k of this.children) t += k?.textContent || "";
      return t;
    },
  };
  return el;
}

function E(tag: string, a?: any, c?: any) {
  const el = makeEl(tag);
  function add(x: any) {
    if (x == null) return;
    if (Array.isArray(x)) {
      x.forEach(add);
      return;
    }
    if (typeof x === "string") {
      el._t += x;
      return;
    }
    el.children.push(x);
  }
  let kids = c;
  if (a && typeof a === "object" && !Array.isArray(a) && a.tag === undefined) {
    // a is an attrs object
  } else {
    kids = a;
  }
  add(kids);
  return el;
}

function loadStatusPanel() {
  const src = readFileSync(STATUS_PANEL_JS, "utf8");
  const body = src
    .replace(/^'use strict';\s*/, "")
    .replace(/^'require [^']+';\s*/gm, "")
    .replace(
      /return L\.Class\.extend\((\{[\s\S]*\})\);?\s*$/,
      "__moduleExports = $1;",
    );

  let statusImpl: () => Promise<any> = () =>
    Promise.resolve({ status: "ok", running: true, now: 0 });

  const sandbox: Record<string, unknown> = {
    __moduleExports: null,
    _: (s: unknown) => s,
    E,
    L: { Class: { extend: (o: unknown) => o } },
    Math,
    Object,
    Array,
    Promise,
    Number,
    String,
    console: { log() {}, error() {}, warn() {} },
    SbRpc: { callStatus: (..._a: unknown[]) => statusImpl() },
    __test: {
      setStatus: (fn: () => Promise<any>) => {
        statusImpl = fn;
      },
    },
  };

  vm.createContext(sandbox);
  vm.runInContext(`(function(){${body}})();`, sandbox, {
    filename: "status-panel.js",
  });

  return sandbox as any;
}

describe("status-panel.js renderStatusPanel (S2-1)", () => {
  it("renderStatusPanel swallows RPC rejection and does not reject (S2-1)", async () => {
    const ctx = loadStatusPanel();
    ctx.__test.setStatus(() => Promise.reject(new Error("rpcd gone")));
    const holder = E("div", {});
    let rejected = false;
    await ctx.__moduleExports.renderStatusPanel(holder).catch(() => {
      rejected = true;
    });
    expect(rejected).toBe(false);
  });
});
