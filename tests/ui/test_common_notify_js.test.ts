import { describe, expect, it } from "bun:test";
import { resolve } from "node:path";
import { loadLuciModule } from "../helpers/luci.ts";

// tests/test_common_notify_js.sh — notify() must not TypeError when the
// rejection reason is null/undefined (spec S2-7).

const COMMON_JS = resolve(
  import.meta.dir,
  "../../luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/lib/common.js",
);

const notes: string[] = [];

const { exports: C } = loadLuciModule(COMMON_JS, {
  _: (s: unknown) => s,
  E: (t: unknown, c?: unknown) => ({
    tag: t,
    _t: typeof c === "string" ? c : "",
  }),
  ui: {
    addNotification: (_a: unknown, node: any, _kind: unknown) => {
      notes.push(node?._t);
    },
    showModal() {},
    hideModal() {},
  },
  form: { Value: () => {}, ListValue: () => {} },
  uci: { sections: () => [], rename() {} },
  Promise,
  Object,
  Array,
  document: { body: { appendChild() {}, removeChild() {} } },
  window: {},
});

describe("common.js notify (S2-7)", () => {
  it("notify() does not throw / reject on null rejection reason", async () => {
    let threw = false;
    await C.notify(Promise.reject(null), "ok", "Failed").catch(() => {
      threw = true;
    });
    expect(threw).toBe(false);
  });

  it("notify() still posts a danger notification on failure", async () => {
    // Re-run notify to capture a fresh notification (notes may already contain one from above)
    const before = notes.length;
    await C.notify(Promise.reject(null), "ok", "Failed").catch(() => {});
    const added = notes.slice(before);
    expect(
      added.some((t) => typeof t === "string" && t.indexOf("Failed") >= 0),
    ).toBe(true);
  });
});
