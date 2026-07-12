import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { loadLuciModule } from "../helpers/luci.ts";

// waitSubRefresh() backs the async subscription refresh: the RPC returns as
// soon as the fetch is FORKED, so "done" is whatever the progress side-car
// says. Two things must hold, or the UI lies about the outcome:
//   * it keeps polling while progress.running is set (and reports each tick),
//   * it gives up after a bounded number of tries, so a child that dies without
//     clearing running:1 does not spin the button forever.

const COMMON_JS = resolve(
  import.meta.dirname,
  "../../luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/lib/common.js",
);

function loadCommon(replies: unknown[]) {
  let n = 0;
  const calls = { count: 0 };
  const { exports } = loadLuciModule(COMMON_JS, {
    _: (s: unknown) => s,
    E: (t: unknown) => ({ tag: t }),
    ui: { addNotification() {}, showModal() {}, hideModal() {} },
    form: { Value: () => {}, ListValue: () => {} },
    uci: { sections: () => [], rename() {} },
    SbRpc: {
      callSubStatus: () => {
        calls.count++;
        return Promise.resolve(replies[Math.min(n++, replies.length - 1)]);
      },
    },
    Promise,
    Object,
    Array,
    Math,
    document: { body: { appendChild() {}, removeChild() {} } },
    // fire the poll interval immediately — we are testing the loop, not the clock
    window: { setTimeout: (fn: () => void) => fn() },
  });
  return { C: exports, calls };
}

describe("common.js waitSubRefresh", () => {
  it("polls until the backend reports the run finished, ticking on every reply", async () => {
    const { C, calls } = loadCommon([
      { progress: { running: 1, total: 3, done: 0 } },
      { progress: { running: 1, total: 3, done: 2 } },
      { progress: { running: 0, total: 3, done: 3 } },
    ]);
    const seen: number[] = [];
    const res = await C.waitSubRefresh((r: any) => seen.push(r.progress.done));

    expect(calls.count).toBe(3);
    expect(seen).toEqual([0, 2, 3]);
    expect((res as any).progress.running).toBe(0);
  });

  it("stops when the backend has no progress at all (old handler / nothing queued)", async () => {
    const { C, calls } = loadCommon([{ subscriptions: [] }]);
    await C.waitSubRefresh();
    expect(calls.count).toBe(1);
  });

  it("gives up on a run that never clears running:1", async () => {
    const { C, calls } = loadCommon([
      { progress: { running: 1, total: 1, done: 0 } },
    ]);
    await C.waitSubRefresh();
    expect(calls.count).toBeLessThanOrEqual(202); // MAX_TICKS + the final read
    expect(calls.count).toBeGreaterThan(10);
  });
});
