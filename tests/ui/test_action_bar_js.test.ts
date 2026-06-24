import { describe, expect, it } from "bun:test";
import { resolve } from "node:path";
import { loadLuciModule } from "../helpers/luci.ts";

// uis-4: btn() must NOT re-translate an already-translated label. Callers pass
// _()-wrapped strings; btn() previously called _() again. We mock _ as a
// non-identity wrapper "T[...]" so a double-translation would surface as the
// nested "T[T[...]]" — an identity mock (s => s) could never catch the bug.

const ACTION_BAR_JS = resolve(
  import.meta.dir,
  "../../luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/widgets/action-bar.js",
);

function tr(s: unknown): string {
  return `T[${s}]`;
}

function E(tag: string, attrs?: any, children?: any): any {
  const el: any = { tag, attrs: attrs || {}, children: [], textContent: "" };
  const kids = children !== undefined ? children : attrs;
  if (typeof kids === "string") el.textContent = kids;
  else if (Array.isArray(kids)) el.children = kids.filter(Boolean);
  else if (kids && typeof kids === "object" && kids.tag) el.children = [kids];
  return el;
}

function collectButtons(node: any, out: any[] = []): any[] {
  if (!node || typeof node !== "object") return out;
  if (node.tag === "button") out.push(node);
  for (const c of node.children || []) collectButtons(c, out);
  return out;
}

const noopRpc = {
  callRefresh: () => Promise.resolve(),
  callRestart: () => Promise.resolve(),
  callReadConfig: () => Promise.resolve(),
  callPreviewConfig: () => Promise.resolve(),
};
const noopCommon = {
  notify: () => Promise.resolve(),
  showJsonModal: () => {},
  withBusy: (_btn: unknown, _busy: unknown, fn: () => unknown) =>
    Promise.resolve().then(fn),
};
const noopStatusPanel = { renderStatusPanel: () => {} };

describe("action-bar.js btn() (uis-4: no double-translate)", () => {
  it("renders each button label translated exactly once", () => {
    const { exports } = loadLuciModule(ACTION_BAR_JS, {
      _: tr,
      E,
      ui: { createHandlerFn: (_ctx: unknown, fn: unknown) => fn },
      Promise,
      SbRpc: noopRpc,
      SbCommon: noopCommon,
      SbStatusPanel: noopStatusPanel,
    });
    const bar = exports.renderActionBar({ tag: "div", children: [] });
    const labels = collectButtons(bar).map((b) => b.textContent);

    // Callers pass _('Refresh subscriptions') etc., so each button text must be
    // SINGLE-wrapped. A double-translating btn() would yield "T[T[...]]".
    expect(labels).toContain("T[Refresh subscriptions]");
    expect(labels).toContain("T[Refresh rule-sets]");
    expect(labels).toContain("T[Restart service]");
    expect(labels.some((l) => l.startsWith("T[T["))).toBe(false);
  });
});
