import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import vm from "node:vm";

// tests/test_dashboard_js.sh — vm sandbox for tabs/dashboard.js.
// Mirrors test_monitoring_js.sh approach: load fragment into vm context with
// minimal DOM/LuCI/SbRpc stubs and assert rendering + behavior.

const DASHBOARD_JS = resolve(
  import.meta.dir,
  "../../luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/tabs/dashboard.js",
);

// ---- DOM helpers -----------------------------------------------------------

function makeEl(tag: string): any {
  const el: any = {
    tag,
    children: [] as any[],
    attrs: {} as Record<string, any>,
    _text: "",
    isConnected: true,
    appendChild(c: any) {
      if (c) this.children.push(c);
      return c;
    },
    set innerHTML(v: string) {
      if (v === "") this.children = [];
    },
    get innerHTML() {
      return "";
    },
    set textContent(v: string) {
      this._text = String(v);
      this.children = [];
    },
    get textContent(): string {
      let t = this._text || "";
      for (const c of this.children) t += c?.textContent || "";
      return t;
    },
    querySelectorAll() {
      return [];
    },
    set className(v: string) {
      this.attrs.class = String(v);
    },
    get className(): string {
      return this.attrs.class || "";
    },
  };
  return el;
}

function E(tag: string, a?: any, c?: any): any {
  const el = makeEl(tag);
  let kids = c;
  if (a && typeof a === "object" && !Array.isArray(a) && a.tag === undefined) {
    el.attrs = a;
  } else {
    kids = a;
  }
  function add(x: any) {
    if (x == null) return;
    if (Array.isArray(x)) {
      x.forEach(add);
      return;
    }
    if (typeof x === "string") {
      el._text += x;
      return;
    }
    el.children.push(x);
  }
  add(kids);
  return el;
}

// ---- tree helpers ----------------------------------------------------------

function findNode(n: any, pred: (n: any) => boolean): any {
  if (!n) return null;
  if (pred(n)) return n;
  for (const k of n.children || []) {
    const r = findNode(k, pred);
    if (r) return r;
  }
  return null;
}

function findAll(n: any, pred: (n: any) => boolean, out: any[] = []): any[] {
  if (!n) return out;
  if (pred(n)) out.push(n);
  for (const k of n.children || []) findAll(k, pred, out);
  return out;
}

// ---- load dashboard --------------------------------------------------------

function loadDashboard() {
  const src = readFileSync(DASHBOARD_JS, "utf8");
  const body = src
    .replace(/^'use strict';\s*/, "")
    .replace(/^'require [^']+';\s*/gm, "")
    .replace(
      /return L\.Class\.extend\((\{[\s\S]*\})\);?\s*$/,
      "__moduleExports = $1;",
    );

  let intervalId = 0;
  let timeoutId = 0;
  const intervals: Record<string, { fn: () => void; ms: number }> = {};
  const timeouts: Record<string, () => void> = {};

  let clashGet: (...a: unknown[]) => Promise<any> = () =>
    Promise.resolve({ status: "ok", body: "{}" });
  let clashMutate: (...a: unknown[]) => Promise<any> = () =>
    Promise.resolve({ status: "ok" });
  let clashDelay: (...a: unknown[]) => Promise<any> = () =>
    Promise.resolve({ status: "ok", body: '{"delay":0}' });
  let subStatus: (...a: unknown[]) => Promise<any> = () => Promise.resolve([]);
  let clashRefresh: (...a: unknown[]) => Promise<any> = () =>
    Promise.resolve({ status: "ok" });

  const sandbox: Record<string, unknown> = {
    __moduleExports: null,
    _: (s: unknown) => s,
    E,
    L: { Class: { extend: (o: unknown) => o } },
    ui: {
      createHandlerFn: (_ctx: unknown, fn: unknown) => fn,
      addNotification: () => {},
    },
    document: {
      visibilityState: "visible",
      addEventListener() {},
      removeEventListener() {},
    },
    window: { addEventListener() {}, removeEventListener() {} },
    setInterval: (fn: () => void, ms: number) => {
      const id = ++intervalId;
      intervals[id] = { fn, ms };
      return id;
    },
    clearInterval: (id: number) => {
      delete intervals[id];
    },
    setTimeout: (fn: () => void) => {
      const id = ++timeoutId;
      timeouts[id] = fn;
      return id;
    },
    clearTimeout: (id: number) => {
      delete timeouts[id];
    },
    Math,
    Object,
    Array,
    JSON,
    Promise,
    Number,
    Date,
    console: { log: () => {}, error: () => {}, warn: () => {} },
    SbRpc: {
      callClashGet: (...a: unknown[]) => clashGet(...a),
      callClashMutate: (...a: unknown[]) => clashMutate(...a),
      callClashDelay: (...a: unknown[]) => clashDelay(...a),
      callSubStatus: (...a: unknown[]) => subStatus(...a),
      callRefresh: (...a: unknown[]) => clashRefresh(...a),
    },
    __test: {
      intervals,
      timeouts,
      setGet: (fn: typeof clashGet) => {
        clashGet = fn;
      },
      setMutate: (fn: typeof clashMutate) => {
        clashMutate = fn;
      },
      setDelay: (fn: typeof clashDelay) => {
        clashDelay = fn;
      },
      setSub: (fn: typeof subStatus) => {
        subStatus = fn;
      },
      setRefresh: (fn: typeof clashRefresh) => {
        clashRefresh = fn;
      },
      fireInterval: (id: string | number) => intervals[id as any]?.fn(),
      find: findNode,
      findAll,
    },
  };

  vm.createContext(sandbox);
  // Patch String.prototype.format inside the vm context
  vm.runInContext(
    `if(!String.prototype.format){String.prototype.format=function(){var a=arguments,i=0;return this.replace(/%[sd]/g,function(){return ""+a[i++];});};}`,
    sandbox,
  );
  vm.runInContext(`(function(){${body}})();`, sandbox, {
    filename: "dashboard.js",
  });
  return sandbox as any;
}

// ---- tests -----------------------------------------------------------------

describe("dashboard.js", () => {
  it("poll() renders connections count and core version", async () => {
    const ctx = loadDashboard();
    const Dash = ctx.__moduleExports;
    ctx.__test.setGet((path: string) => {
      if (path === "/connections")
        return Promise.resolve({
          status: "ok",
          body: JSON.stringify({
            connections: [{ id: "1" }, { id: "2" }],
            downloadTotal: 2048,
            uploadTotal: 1024,
          }),
        });
      if (path === "/version")
        return Promise.resolve({ status: "ok", body: '{"version":"1.12.0"}' });
      if (path === "/proxies")
        return Promise.resolve({ status: "ok", body: '{"proxies":{}}' });
      return Promise.resolve({ status: "ok", body: "{}" });
    });
    const d = Dash.buildDashboard();
    await d.poll();
    const txt = d.node.textContent;
    expect(txt.indexOf("2") >= 0).toBe(true);
    expect(txt.indexOf("1.12.0") >= 0).toBe(true);
  });

  it("poll() swallows rejection when clash is down", async () => {
    const ctx = loadDashboard();
    const Dash = ctx.__moduleExports;
    ctx.__test.setGet(() => Promise.reject(new Error("down")));
    const d2 = Dash.buildDashboard();
    let rejected = false;
    await d2.poll().catch(() => {
      rejected = true;
    });
    expect(rejected).toBe(false);
    expect(d2.node.textContent.indexOf("Clash API") >= 0).toBe(true);
  });

  it("interval self-cancels when root is detached", async () => {
    const ctx = loadDashboard();
    const Dash = ctx.__moduleExports;
    ctx.__test.setGet(() =>
      Promise.resolve({ status: "ok", body: '{"connections":[]}' }),
    );
    const d3 = Dash.buildDashboard();
    d3.start();
    const ids = Object.keys(ctx.__test.intervals);
    expect(ids.length >= 1).toBe(true);
    d3.node.isConnected = false;
    ctx.__test.fireInterval(ids[0]);
    expect(Object.keys(ctx.__test.intervals).length).toBe(0);
  });

  it("renders selector + urltest groups", async () => {
    const ctx = loadDashboard();
    const Dash = ctx.__moduleExports;
    const PROXIES = {
      proxies: {
        GW: { type: "Selector", now: "A", all: ["A", "B"] },
        A: { type: "Shadowsocks", history: [{ delay: 120 }] },
        B: { type: "Vmess", history: [{ delay: 900 }] },
        AUTO: { type: "URLTest", now: "A", all: ["A", "B"] },
      },
    };
    ctx.__test.setGet((path: string) => {
      if (path === "/proxies")
        return Promise.resolve({ status: "ok", body: JSON.stringify(PROXIES) });
      if (path === "/connections")
        return Promise.resolve({ status: "ok", body: '{"connections":[]}' });
      if (path === "/version")
        return Promise.resolve({ status: "ok", body: '{"version":"1.12.0"}' });
      return Promise.resolve({ status: "ok", body: "{}" });
    });
    const g = Dash.buildDashboard();
    await g.poll();
    await g.refreshProxies();
    const isGroup = (n: any) =>
      n.attrs && /sb-dashboard-group\b/.test(n.attrs.class || "");
    expect(findAll(g.node, isGroup).length).toBe(2);
    const isCurrent = (n: any) =>
      n.attrs && /sb-dashboard-node-current/.test(n.attrs.class || "");
    expect(findAll(g.node, isCurrent).length >= 2).toBe(true);
    const hasGood = findNode(
      g.node,
      (n: any) => n.attrs && /sb-lat-good/.test(n.attrs.class || ""),
    );
    const hasBad = findNode(
      g.node,
      (n: any) => n.attrs && /sb-lat-bad/.test(n.attrs.class || ""),
    );
    expect(!!hasGood).toBe(true);
    expect(!!hasBad).toBe(true);
    const urltestRows = findAll(
      g.node,
      (n: any) =>
        n.attrs &&
        /sb-dashboard-node\b/.test(n.attrs.class || "") &&
        n.attrs["data-group"] === "AUTO",
    );
    expect(urltestRows.length >= 1).toBe(true);
    expect(
      urltestRows.every((r: any) => typeof r.attrs.click !== "function"),
    ).toBe(true);
  });

  it("poll() does not refetch /proxies while a latency test is in flight (regression: wiped results)", async () => {
    const ctx = loadDashboard();
    const Dash = ctx.__moduleExports;
    const PROXIES = {
      proxies: {
        GW: { type: "Selector", now: "A", all: ["A", "B"] },
        A: { type: "Shadowsocks", history: [{ delay: 120 }] },
        B: { type: "Vmess", history: [{ delay: 900 }] },
      },
    };
    let proxiesCalls = 0;
    ctx.__test.setGet((path: string) => {
      if (path === "/proxies") {
        proxiesCalls++;
        return Promise.resolve({ status: "ok", body: JSON.stringify(PROXIES) });
      }
      if (path === "/connections")
        return Promise.resolve({ status: "ok", body: '{"connections":[]}' });
      if (path === "/version")
        return Promise.resolve({ status: "ok", body: '{"version":"1.12.0"}' });
      return Promise.resolve({ status: "ok", body: "{}" });
    });
    // A latency probe that never resolves keeps GW flagged "testing".
    ctx.__test.setDelay(() => new Promise<void>(() => {}));
    const d = Dash.buildDashboard();
    await d.poll();
    await d.refreshProxies();
    const before = proxiesCalls;
    // Start a test on GW; its probe hangs, so state.testing[GW] stays true.
    const testBtn = ctx.__test.find(
      d.node,
      (n: any) =>
        n.attrs &&
        typeof n.attrs.click === "function" &&
        /sb-dashboard-test/.test(n.attrs.class || ""),
    );
    expect(!!testBtn).toBe(true);
    testBtn.attrs.click(); // fire-and-forget; probe never resolves
    // One of these polls hits the every-3rd /proxies fetch tick, which must be
    // suppressed while a test is in flight (else it wipes the collected history).
    await d.poll();
    await d.poll();
    await d.poll();
    expect(proxiesCalls).toBe(before);
  });

  it("selector switch sends PUT /proxies/<group> {name}", async () => {
    const ctx = loadDashboard();
    const Dash = ctx.__moduleExports;
    const PROXIES = {
      proxies: {
        GW: { type: "Selector", now: "A", all: ["A", "B"] },
        A: { type: "Shadowsocks", history: [{ delay: 120 }] },
        B: { type: "Vmess", history: [{ delay: 900 }] },
        AUTO: { type: "URLTest", now: "A", all: ["A", "B"] },
      },
    };
    ctx.__test.setGet((path: string) => {
      if (path === "/proxies")
        return Promise.resolve({ status: "ok", body: JSON.stringify(PROXIES) });
      if (path === "/connections")
        return Promise.resolve({ status: "ok", body: '{"connections":[]}' });
      if (path === "/version")
        return Promise.resolve({ status: "ok", body: '{"version":"1.12.0"}' });
      return Promise.resolve({ status: "ok", body: "{}" });
    });
    let putPath = "";
    let putBody = "";
    ctx.__test.setMutate((method: string, path: string, bodyStr: string) => {
      putPath = `${method} ${path}`;
      putBody = bodyStr;
      return Promise.resolve({ status: "ok" });
    });
    const s = Dash.buildDashboard();
    await s.poll();
    await s.refreshProxies();
    const aRow = findNode(
      s.node,
      (n: any) =>
        n.attrs &&
        n.attrs["data-group"] === "GW" &&
        n.attrs["data-name"] === "B" &&
        typeof n.attrs.click === "function",
    );
    expect(!!aRow).toBe(true);
    await aRow.attrs.click();
    expect(putPath).toBe("PUT /proxies/GW");
    expect(JSON.parse(putBody).name).toBe("B");
  });

  it("Test button calls callClashDelay per member", async () => {
    const ctx = loadDashboard();
    const Dash = ctx.__moduleExports;
    const PROXIES = {
      proxies: {
        GW: { type: "Selector", now: "A", all: ["A", "B"] },
        A: { type: "Shadowsocks", history: [{ delay: 120 }] },
        B: { type: "Vmess", history: [{ delay: 900 }] },
        AUTO: { type: "URLTest", now: "A", all: ["A", "B"] },
      },
    };
    ctx.__test.setGet((path: string) => {
      if (path === "/proxies")
        return Promise.resolve({ status: "ok", body: JSON.stringify(PROXIES) });
      if (path === "/connections")
        return Promise.resolve({ status: "ok", body: '{"connections":[]}' });
      if (path === "/version")
        return Promise.resolve({ status: "ok", body: '{"version":"1.12.0"}' });
      return Promise.resolve({ status: "ok", body: "{}" });
    });
    const tested: string[] = [];
    ctx.__test.setDelay((name: string) => {
      tested.push(name);
      return Promise.resolve({
        status: "ok",
        body: JSON.stringify({ delay: 42 }),
      });
    });
    const t = Dash.buildDashboard();
    await t.poll();
    await t.refreshProxies();
    const testBtn = findNode(
      t.node,
      (n: any) =>
        n.tag === "button" &&
        /sb-dashboard-test/.test(n.attrs?.class || "") &&
        typeof n.attrs?.click === "function",
    );
    await testBtn.attrs.click();
    expect(tested.indexOf("A") >= 0).toBe(true);
    expect(tested.indexOf("B") >= 0).toBe(true);
  });

  it("sort-by-latency reorders members fastest-first", async () => {
    const ctx = loadDashboard();
    const Dash = ctx.__moduleExports;
    const PROXIES = {
      proxies: {
        GW: { type: "Selector", now: "A", all: ["A", "B"] },
        A: { type: "Shadowsocks", history: [{ delay: 120 }] },
        B: { type: "Vmess", history: [{ delay: 900 }] },
        AUTO: { type: "URLTest", now: "A", all: ["A", "B"] },
      },
    };
    ctx.__test.setGet((path: string) => {
      if (path === "/proxies")
        return Promise.resolve({ status: "ok", body: JSON.stringify(PROXIES) });
      if (path === "/connections")
        return Promise.resolve({ status: "ok", body: '{"connections":[]}' });
      if (path === "/version")
        return Promise.resolve({ status: "ok", body: '{"version":"1.12.0"}' });
      return Promise.resolve({ status: "ok", body: "{}" });
    });
    const so = Dash.buildDashboard();
    so.setSortByLatency(true);
    await so.poll();
    await so.refreshProxies();
    const names = findAll(
      so.node,
      (n: any) => n.attrs && /sb-dashboard-node-name/.test(n.attrs.class || ""),
    ).map((n: any) => n.textContent);
    expect(names.indexOf("A") >= 0).toBe(true);
    expect(names.indexOf("A") < names.indexOf("B")).toBe(true);
  });

  it("uis-1: sort/memberDelay uses the NEWEST (last) history sample, not the oldest", async () => {
    const ctx = loadDashboard();
    const Dash = ctx.__moduleExports;
    // clash/mihomo appends the newest probe LAST. B's multi-sample history ends
    // at 50ms (fast); reading history[0] (900, the OLD code) would sort A first.
    // Reading the tail (the fix) makes B fastest, so B must sort before A.
    const PROXIES = {
      proxies: {
        GW: { type: "Selector", now: "A", all: ["A", "B"] },
        A: { type: "Shadowsocks", history: [{ delay: 300 }] },
        B: {
          type: "Vmess",
          history: [{ delay: 900 }, { delay: 600 }, { delay: 50 }],
        },
      },
    };
    ctx.__test.setGet((path: string) => {
      if (path === "/proxies")
        return Promise.resolve({ status: "ok", body: JSON.stringify(PROXIES) });
      if (path === "/connections")
        return Promise.resolve({ status: "ok", body: '{"connections":[]}' });
      if (path === "/version")
        return Promise.resolve({ status: "ok", body: '{"version":"1.12.0"}' });
      return Promise.resolve({ status: "ok", body: "{}" });
    });
    const so = Dash.buildDashboard();
    so.setSortByLatency(true);
    await so.poll();
    await so.refreshProxies();
    const names = findAll(
      so.node,
      (n: any) => n.attrs && /sb-dashboard-node-name/.test(n.attrs.class || ""),
    ).map((n: any) => n.textContent);
    expect(names.indexOf("B") >= 0).toBe(true);
    expect(names.indexOf("B") < names.indexOf("A")).toBe(true);
  });

  it("subscription status strip + Update button on subscription groups", async () => {
    const ctx = loadDashboard();
    const Dash = ctx.__moduleExports;
    const PX2 = {
      proxies: {
        mysub: { type: "Selector", now: "A", all: ["A"] },
        A: { type: "Vmess", history: [{ delay: 50 }] },
      },
    };
    ctx.__test.setGet((path: string) => {
      if (path === "/proxies")
        return Promise.resolve({ status: "ok", body: JSON.stringify(PX2) });
      if (path === "/connections")
        return Promise.resolve({ status: "ok", body: '{"connections":[]}' });
      if (path === "/version")
        return Promise.resolve({ status: "ok", body: '{"version":"1.12.0"}' });
      return Promise.resolve({ status: "ok", body: "{}" });
    });
    ctx.__test.setSub(() =>
      Promise.resolve({
        status: "ok",
        subscriptions: [
          {
            name: "mysub",
            enabled: "1",
            last_update: Math.floor(Date.now() / 1000) - 120,
            node_count: 7,
          },
        ],
      }),
    );
    let refreshed = "";
    ctx.__test.setRefresh((what: string, name: string) => {
      refreshed = `${what}:${name}`;
      return Promise.resolve({ status: "ok" });
    });
    const sd = Dash.buildDashboard();
    await sd.poll();
    await sd.refreshProxies();
    await sd.refreshSubs();
    expect(sd.node.textContent.indexOf("7") >= 0).toBe(true);
    const upd = findNode(
      sd.node,
      (n: any) =>
        n.tag === "button" &&
        /sb-dashboard-sub-update/.test(n.attrs?.class || "") &&
        typeof n.attrs?.click === "function",
    );
    expect(!!upd).toBe(true);
    await upd.attrs.click();
    expect(refreshed).toBe("subscriptions:mysub");
  });

  it("DASH-3: non-expanded subscription gets its own row", async () => {
    const ctx = loadDashboard();
    const Dash = ctx.__moduleExports;
    ctx.__test.setGet((path: string) => {
      if (path === "/proxies")
        return Promise.resolve({ status: "ok", body: '{"proxies":{}}' });
      if (path === "/connections")
        return Promise.resolve({ status: "ok", body: '{"connections":[]}' });
      if (path === "/version")
        return Promise.resolve({ status: "ok", body: '{"version":"1.12.0"}' });
      return Promise.resolve({ status: "ok", body: "{}" });
    });
    const nowTs = Math.floor(Date.now() / 1000);
    ctx.__test.setSub(() =>
      Promise.resolve({
        status: "ok",
        now: nowTs,
        subscriptions: [
          {
            name: "plainsub",
            enabled: "1",
            last_update: nowTs - 60,
            node_count: 13,
            title: "My Plan",
            userinfo: {
              upload: 100,
              download: 200,
              total: 1000,
              expire: nowTs + 86400,
            },
          },
        ],
      }),
    );
    const d3s = Dash.buildDashboard();
    await d3s.poll();
    await d3s.refreshProxies();
    await d3s.refreshSubs();
    const subsBox = findNode(
      d3s.node,
      (n: any) => n.attrs && /sb-dashboard-subs/.test(n.attrs.class || ""),
    );
    expect(!!subsBox).toBe(true);
    const subRow = findNode(
      d3s.node,
      (n: any) => n.attrs && n.attrs["data-sub"] === "plainsub",
    );
    expect(!!subRow).toBe(true);
    expect(subRow.textContent.indexOf("13") >= 0).toBe(true);
    expect(subRow.textContent.indexOf("My Plan") >= 0).toBe(true);
  });

  it("DASH-2: 'updated ago' uses server clock, not browser clock", async () => {
    const ctx = loadDashboard();
    const Dash = ctx.__moduleExports;
    const serverNow = Math.floor(Date.now() / 1000) + 100000;
    ctx.__test.setGet((path: string) => {
      if (path === "/proxies")
        return Promise.resolve({ status: "ok", body: '{"proxies":{}}' });
      if (path === "/connections")
        return Promise.resolve({ status: "ok", body: '{"connections":[]}' });
      if (path === "/version")
        return Promise.resolve({ status: "ok", body: '{"version":"1.12.0"}' });
      return Promise.resolve({ status: "ok", body: "{}" });
    });
    ctx.__test.setSub(() =>
      Promise.resolve({
        status: "ok",
        now: serverNow,
        subscriptions: [
          {
            name: "clocksub",
            enabled: "1",
            last_update: serverNow - 3600,
            node_count: 1,
          },
        ],
      }),
    );
    const d2c = Dash.buildDashboard();
    await d2c.poll();
    await d2c.refreshProxies();
    await d2c.refreshSubs();
    const clockRow = findNode(
      d2c.node,
      (n: any) => n.attrs && n.attrs["data-sub"] === "clocksub",
    );
    expect(clockRow && clockRow.textContent.indexOf("1h") >= 0).toBe(true);
  });

  it("DASH-1: Test button shows busy state and bounds concurrency to ≤8", async () => {
    const ctx = loadDashboard();
    const Dash = ctx.__moduleExports;
    const MANY: any = {
      proxies: { BIG: { type: "Selector", now: "n0", all: [] } },
    };
    for (let k = 0; k < 20; k++) {
      const nm = `n${k}`;
      MANY.proxies.BIG.all.push(nm);
      MANY.proxies[nm] = { type: "Shadowsocks", history: [{ delay: 0 }] };
    }
    ctx.__test.setGet((path: string) => {
      if (path === "/proxies")
        return Promise.resolve({ status: "ok", body: JSON.stringify(MANY) });
      if (path === "/connections")
        return Promise.resolve({ status: "ok", body: '{"connections":[]}' });
      if (path === "/version")
        return Promise.resolve({ status: "ok", body: '{"version":"1.12.0"}' });
      return Promise.resolve({ status: "ok", body: "{}" });
    });
    let inFlight = 0;
    let maxInFlight = 0;
    const release: (() => void)[] = [];
    ctx.__test.setDelay((_name: string) => {
      inFlight++;
      if (inFlight > maxInFlight) maxInFlight = inFlight;
      return new Promise((res) => {
        release.push(() => {
          inFlight--;
          res({ status: "ok", body: '{"delay":10}' });
        });
      });
    });
    const dl = Dash.buildDashboard();
    await dl.poll();
    await dl.refreshProxies();
    const findTestBtn = () =>
      findNode(
        dl.node,
        (n: any) =>
          n.tag === "button" && /sb-dashboard-test/.test(n.attrs?.class || ""),
      );
    const tp = findTestBtn().attrs.click();
    await Promise.resolve();
    await Promise.resolve();
    const busyBtn = findTestBtn();
    expect(busyBtn && busyBtn.attrs.disabled !== undefined).toBe(true);
    expect((busyBtn?.textContent || "").indexOf("Testing") >= 0).toBe(true);
    while (release.length) {
      const batch = release.splice(0);
      for (const f of batch) f();
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();
    }
    await tp;
    expect(maxInFlight > 0 && maxInFlight <= 8).toBe(true);
    const doneBtn = findTestBtn();
    expect(doneBtn && doneBtn.attrs.disabled === undefined).toBe(true);
    expect((doneBtn?.textContent || "") === "Test").toBe(true);
  });
});
