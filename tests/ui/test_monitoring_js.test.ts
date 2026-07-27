import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import vm from "node:vm";
import { describe, expect, it } from "vitest";

// tests/test_monitoring_js.sh — Node harness for tabs/monitoring.js.
// Asserts async-safety + DOM-stability of the connection monitor.

const MONITORING_JS = resolve(
  import.meta.dirname,
  "../../luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/tabs/monitoring.js",
);

// ---- minimal DOM/LuCI stubs (mirrors the original .sh exactly) -------------

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
    // _html records what went through innerHTML. LuCI's dom.append() assigns
    // innerHTML for a BARE STRING child (only an array becomes text nodes), so
    // this is the XSS path and the stub must keep the two apart.
    _html: "",
    set innerHTML(v: string) {
      this._html = String(v);
      this.children = [];
      this._text = "";
    },
    get innerHTML() {
      return this._html;
    },
    set textContent(v: string) {
      this._text = String(v);
      this._html = "";
      this.children = [];
    },
    get textContent(): string {
      let t = this._text || this._html || "";
      for (const c of this.children) t += c?.textContent || "";
      return t;
    },
    scrollTop: 0,
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
  // Mirrors LuCI dom.append(): an ARRAY makes a text node per string child; a
  // bare string is assigned to innerHTML.
  if (Array.isArray(kids)) {
    for (const k of kids) {
      if (k == null) continue;
      if (typeof k === "object") el.children.push(k);
      else el._text += String(k);
    }
  } else if (kids != null) {
    if (typeof kids === "object") el.children.push(kids);
    else el.innerHTML = String(kids);
  }
  return el;
}

function loadMonitoring() {
  const src = readFileSync(MONITORING_JS, "utf8");
  const body = src
    .replace(/^'use strict';\s*/, "")
    .replace(/^'require [^']+';\s*/gm, "")
    .replace(
      /return L\.Class\.extend\((\{[\s\S]*\})\);?\s*$/,
      "__moduleExports = $1;",
    );

  let intervalId = 0;
  const intervals: Record<string, { fn: () => void; ms: number }> = {};
  const timeouts: Record<string, () => void> = {};
  let timeoutId = 0;

  let clashGetImpl: (...a: unknown[]) => Promise<any> = () =>
    Promise.resolve({ status: "ok", body: '{"connections":[]}' });
  let clashMutateImpl: (...a: unknown[]) => Promise<any> = () =>
    Promise.resolve({ status: "ok" });
  let outboundMetaImpl: () => Promise<any> = () =>
    Promise.resolve({ meta: {} });

  const sandbox: Record<string, unknown> = {
    __moduleExports: null,
    _: (s: unknown) => s,
    E,
    L: { Class: { extend: (o: unknown) => o } },
    ui: { createHandlerFn: (_ctx: unknown, fn: unknown) => fn },
    document: {
      visibilityState: "visible",
      addEventListener() {},
      removeEventListener() {},
    },
    window: {
      scrollY: 0,
      scrollTo() {},
      addEventListener() {},
      removeEventListener() {},
    },
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
    // The host Date, deliberately: the duration tests advance Date.now() and the
    // module must see the same intrinsic the test patched.
    Date,
    Object,
    Array,
    JSON,
    Promise,
    Number,
    String,
    console: { log() {}, error() {}, warn() {} },
    SbRpc: {
      callClashGet: (...a: unknown[]) => clashGetImpl(...a),
      callClashMutate: (...a: unknown[]) => clashMutateImpl(...a),
      callDhcpLeases: () => Promise.resolve({ leases: [] }),
      callOutboundMeta: () => outboundMetaImpl(),
    },
    // lib/icons.js builds real SVG nodes via createElementNS; the harness only
    // needs something appendable.
    SbIcons: {
      x: () => makeEl("svg"),
      pause: () => makeEl("svg"),
      play: () => makeEl("svg"),
      search: () => makeEl("svg"),
    },
    SbCommon: {
      prettyBytes: (n: number) => {
        n = +n || 0;
        if (n < 1000) return `${n} B`;
        const u = ["B", "KB", "MB", "GB", "TB", "PB"];
        const e = Math.min(
          Math.floor(Math.log(n) / Math.log(1000)),
          u.length - 1,
        );
        return `${Number((n / 1000 ** e).toPrecision(3))} ${u[e]}`;
      },
    },
    __test: {
      setOutboundMeta: (fn: () => Promise<any>) => {
        outboundMetaImpl = fn;
      },
      setClashGet: (fn: (...a: unknown[]) => Promise<any>) => {
        clashGetImpl = fn;
      },
      setClashMutate: (fn: (...a: unknown[]) => Promise<any>) => {
        clashMutateImpl = fn;
      },
      get intervals() {
        return intervals;
      },
      get timeouts() {
        return timeouts;
      },
      fireInterval: (id: string | number) => {
        const entry = intervals[id as number];
        if (entry) entry.fn();
      },
      fireAllTimeouts: () => {
        const keys = Object.keys(timeouts);
        for (const k of keys) {
          const f = timeouts[k];
          delete timeouts[k];
          f();
        }
      },
      find(n: any, pred: (n: any) => boolean): any {
        if (!n) return null;
        if (pred(n)) return n;
        const kids = n.children || [];
        const self = sandbox.__test as any;
        for (const kid of kids) {
          const r = self.find(kid, pred);
          if (r) return r;
        }
        return null;
      },
      findAll(n: any, pred: (n: any) => boolean, out: any[] = []): any[] {
        if (!n) return out;
        if (pred(n)) out.push(n);
        const kids = n.children || [];
        const self = sandbox.__test as any;
        for (const kid of kids) self.findAll(kid, pred, out);
        return out;
      },
    },
  };

  vm.createContext(sandbox);
  vm.runInContext(`(function(){${body}})();`, sandbox, {
    filename: "monitoring.js",
  });
  return sandbox as any;
}

// ---- helpers -----------------------------------------------------------------

function conn(
  id: string,
  sourceIP: string,
  host: string,
  chains: string[] = [],
) {
  return { id, metadata: { sourceIP, host }, chains };
}

const isSearch = (n: any) =>
  n.tag === "input" && n.attrs && n.attrs.type === "search";
const isSelect = (n: any) => n.tag === "select" && n.attrs && n.attrs.change;
const isCloseBtn = (n: any) =>
  n.tag === "button" &&
  n.attrs &&
  typeof n.attrs.click === "function" &&
  /^close-/.test(n.attrs["data-action"] || "");
// Both close buttons render as a bare ✕ icon, so they are told apart by
// `data-action` rather than by their label.
const isRowCloseBtn = (n: any) =>
  isCloseBtn(n) && n.attrs["data-action"] === "close-row";
const isCloseAllBtn = (n: any) =>
  isCloseBtn(n) && n.attrs["data-action"] === "close-all";
// The tab buttons are a label span + a count badge span, so their textContent is
// "Active3" — address them by data-action instead of by text.
const isTabBtn = (which: string) => (n: any) =>
  n.tag === "button" && n.attrs && n.attrs["data-action"] === `tab-${which}`;
const tabCount = (n: any) => n.children[1]?.textContent;

// ============================================================================

describe("monitoring.js", () => {
  // S2-1: poll() must not reject when the RPC rejects
  describe("S2-1: poll() RPC failure handling", () => {
    it("poll() swallows RPC rejection (S2-1)", async () => {
      const ctx = loadMonitoring();
      ctx.__test.setClashGet(() => Promise.reject(new Error("ubus down")));
      const m = ctx.__moduleExports.buildMonitoring();
      let rejected = false;
      await m.poll().catch(() => {
        rejected = true;
      });
      expect(rejected).toBe(false);
    });

    it("poll() shows the unavailable state on failure (S2-1)", async () => {
      const ctx = loadMonitoring();
      ctx.__test.setClashGet(() => Promise.reject(new Error("ubus down")));
      const m = ctx.__moduleExports.buildMonitoring();
      await m.poll().catch(() => {});
      expect(
        m.node.textContent.indexOf("Connections are unavailable"),
      ).toBeGreaterThanOrEqual(0);
    });
  });

  // Code review #13: the device filter must be driven by the set actually
  // displayed, so a device whose connections have all closed stays filterable
  // on the Closed tab (previously rebuildDeviceOptions always used curConns()).
  it("Closed tab lists a device whose connections have all closed (audit 9.2+)", async () => {
    const ctx = loadMonitoring();
    const responses = [
      JSON.stringify({ connections: [conn("c1", "10.0.0.5", "hostA")] }),
      JSON.stringify({ connections: [] }),
    ];
    let i = 0;
    ctx.__test.setClashGet(() =>
      Promise.resolve({
        status: "ok",
        body: responses[Math.min(i++, responses.length - 1)],
      }),
    );
    const m = ctx.__moduleExports.buildMonitoring();
    await m.poll(); // c1 active (device 10.0.0.5)
    await m.poll(); // c1 disappears -> moved to state.closed
    // Switch to the Closed tab.
    const closedBtn = ctx.__test.find(m.node, isTabBtn("closed"));
    expect(!!closedBtn).toBe(true);
    closedBtn.attrs.click();
    // 10.0.0.5 exists only among closed connections; it must appear as a device
    // <option> on the Closed tab.
    const selects = ctx.__test.findAll(m.node, isSelect);
    const hasDeviceOpt = selects.some((sel: any) =>
      ctx.__test.find(
        sel,
        (n: any) =>
          n.tag === "option" && n.attrs && n.attrs.value === "10.0.0.5",
      ),
    );
    expect(hasDeviceOpt).toBe(true);
  });

  // S2-2: the interval self-cancels once root detaches
  describe("S2-2: interval self-cancels on detach", () => {
    it("start() registers exactly one interval (S2-2)", async () => {
      const ctx = loadMonitoring();
      ctx.__test.setClashGet(() =>
        Promise.resolve({ status: "ok", body: '{"connections":[]}' }),
      );
      ctx.__test.setClashMutate(() => Promise.resolve({ status: "ok" }));
      const m2 = ctx.__moduleExports.buildMonitoring();
      m2.start();
      const ids = Object.keys(ctx.__test.intervals);
      expect(ids.length).toBe(1);
      // cleanup
      m2.stop();
    });

    it("interval clears itself when root detached (S2-2)", async () => {
      const ctx = loadMonitoring();
      ctx.__test.setClashGet(() =>
        Promise.resolve({ status: "ok", body: '{"connections":[]}' }),
      );
      ctx.__test.setClashMutate(() => Promise.resolve({ status: "ok" }));
      const m2 = ctx.__moduleExports.buildMonitoring();
      m2.start();
      const ids = Object.keys(ctx.__test.intervals);
      m2.node.isConnected = false;
      ctx.__test.fireInterval(ids[0]);
      expect(Object.keys(ctx.__test.intervals).length).toBe(0);
    });
  });

  // S2-3: stop() clears a pending search-debounce timer
  describe("S2-3: stop() clears debounce timer", () => {
    it("debouncedSearch schedules a timeout (S2-3)", async () => {
      const ctx = loadMonitoring();
      ctx.__test.setClashGet(() =>
        Promise.resolve({ status: "ok", body: '{"connections":[]}' }),
      );
      ctx.__test.setClashMutate(() => Promise.resolve({ status: "ok" }));
      const m3 = ctx.__moduleExports.buildMonitoring();
      m3.start();
      m3.debouncedSearch("foo", () => {});
      const tIds = Object.keys(ctx.__test.timeouts);
      expect(tIds.length).toBeGreaterThanOrEqual(1);
      m3.stop();
    });

    it("stop() cleared the debounce timer (S2-3)", async () => {
      const ctx = loadMonitoring();
      ctx.__test.setClashGet(() =>
        Promise.resolve({ status: "ok", body: '{"connections":[]}' }),
      );
      ctx.__test.setClashMutate(() => Promise.resolve({ status: "ok" }));
      const m3 = ctx.__moduleExports.buildMonitoring();
      m3.start();
      m3.debouncedSearch("foo", () => {});
      m3.stop();
      expect(Object.keys(ctx.__test.timeouts).length).toBe(0);
    });
  });

  // S2-4: repaint preserves the search-input element across polls
  describe("S2-4: search input survives repaint", () => {
    it("search input is rendered (S2-4)", async () => {
      const ctx = loadMonitoring();
      ctx.__test.setClashGet(() =>
        Promise.resolve({
          status: "ok",
          body: JSON.stringify({
            connections: [],
            downloadTotal: 0,
            uploadTotal: 0,
          }),
        }),
      );
      const m4 = ctx.__moduleExports.buildMonitoring();
      await m4.poll();
      const search1 = ctx.__test.find(m4.node, isSearch);
      expect(!!search1).toBe(true);
    });

    it("search input survives repaint — same node object (S2-4)", async () => {
      const ctx = loadMonitoring();
      ctx.__test.setClashGet(() =>
        Promise.resolve({
          status: "ok",
          body: JSON.stringify({
            connections: [],
            downloadTotal: 0,
            uploadTotal: 0,
          }),
        }),
      );
      const m4 = ctx.__moduleExports.buildMonitoring();
      await m4.poll();
      const search1 = ctx.__test.find(m4.node, isSearch);
      await m4.poll();
      const search2 = ctx.__test.find(m4.node, isSearch);
      expect(search1 && search1 === search2).toBe(true);
    });
  });

  // S2-6: handlers act on the CURRENT poll's data, not a captured one
  describe("S2-6: live data (no stale closure)", () => {
    it("a per-row Close button is rendered for current data (S2-6)", async () => {
      const ctx = loadMonitoring();
      let s6conns = [conn("a", "10.0.0.1", "old")];
      ctx.__test.setClashGet(() =>
        Promise.resolve({
          status: "ok",
          body: JSON.stringify({
            connections: s6conns,
            downloadTotal: 0,
            uploadTotal: 0,
          }),
        }),
      );
      const m6 = ctx.__moduleExports.buildMonitoring();
      await m6.poll();
      s6conns = [conn("b", "10.0.0.2", "new")];
      await m6.poll();
      const closeBtns = ctx.__test.findAll(m6.node, isCloseBtn);
      expect(closeBtns.length).toBeGreaterThanOrEqual(1);
    });

    it("a row Close acts on latest connection id b, not stale a (S2-6)", async () => {
      const ctx = loadMonitoring();
      let s6conns = [conn("a", "10.0.0.1", "old")];
      ctx.__test.setClashGet(() =>
        Promise.resolve({
          status: "ok",
          body: JSON.stringify({
            connections: s6conns,
            downloadTotal: 0,
            uploadTotal: 0,
          }),
        }),
      );
      const m6 = ctx.__moduleExports.buildMonitoring();
      await m6.poll();
      s6conns = [conn("b", "10.0.0.2", "new")];
      await m6.poll();
      const deletes: string[] = [];
      ctx.__test.setClashMutate((_method: string, path: string) => {
        deletes.push(path);
        return Promise.resolve({ status: "ok" });
      });
      const closeBtns = ctx.__test.findAll(m6.node, isCloseBtn);
      closeBtns.forEach((b: any) => {
        b.attrs.click();
      });
      expect(deletes.indexOf("/connections/b")).toBeGreaterThanOrEqual(0);
      expect(deletes.indexOf("/connections/a")).toBe(-1);
    });

    it("captured device <select> handler exists (S2-6)", async () => {
      const ctx = loadMonitoring();
      const s7conns = [conn("c", "10.0.0.1", "first-only")];
      ctx.__test.setClashGet(() =>
        Promise.resolve({
          status: "ok",
          body: JSON.stringify({
            connections: s7conns,
            downloadTotal: 0,
            uploadTotal: 0,
          }),
        }),
      );
      const m7 = ctx.__moduleExports.buildMonitoring();
      await m7.poll();
      const selHandler = ctx.__test.find(m7.node, isSelect).attrs.change;
      expect(typeof selHandler).toBe("function");
    });

    it("captured handler filters the CURRENT set, not the poll it was built in (S2-6)", async () => {
      const ctx = loadMonitoring();
      let s7conns = [conn("c", "10.0.0.1", "first-only")];
      ctx.__test.setClashGet(() =>
        Promise.resolve({
          status: "ok",
          body: JSON.stringify({
            connections: s7conns,
            downloadTotal: 0,
            uploadTotal: 0,
          }),
        }),
      );
      const m7 = ctx.__moduleExports.buildMonitoring();
      await m7.poll();
      const selHandler = ctx.__test.find(m7.node, isSelect).attrs.change;
      s7conns = [conn("d", "10.0.0.2", "second-only")];
      await m7.poll();
      selHandler({ target: { value: "10.0.0.2" } });
      const hostCells = ctx.__test.findAll(
        m7.node,
        (n: any) =>
          n.tag === "td" && (n.textContent || "").indexOf("second-only") >= 0,
      );
      expect(hostCells.length).toBeGreaterThanOrEqual(1);
    });
  });

  // S2-9: search matches host/chain/source, NOT raw JSON keys
  describe("S2-9: search filtering", () => {
    async function buildSearchMonitor(ctx: any) {
      const s9conn = {
        id: "q",
        metadata: { sourceIP: "10.0.0.9", host: "special-host" },
        chains: ["proxy-A"],
      };
      ctx.__test.setClashGet(() =>
        Promise.resolve({
          status: "ok",
          body: JSON.stringify({
            connections: [s9conn],
            downloadTotal: 0,
            uploadTotal: 0,
          }),
        }),
      );
      const m9 = ctx.__moduleExports.buildMonitoring();
      await m9.poll();
      return m9;
    }

    function typeSearch(ctx: any, m9: any, term: string) {
      const inp = ctx.__test.find(
        m9.node,
        (n: any) => n.tag === "input" && n.attrs && n.attrs.type === "search",
      );
      inp.attrs.keyup({ target: { value: term } });
      ctx.__test.fireAllTimeouts();
    }

    function hostCellMatches(ctx: any, m9: any, text: string) {
      return (
        ctx.__test.findAll(
          m9.node,
          (n: any) =>
            n.tag === "td" && (n.textContent || "").indexOf(text) >= 0,
        ).length >= 1
      );
    }

    it("search matches by host (S2-9)", async () => {
      const ctx = loadMonitoring();
      const m9 = await buildSearchMonitor(ctx);
      typeSearch(ctx, m9, "special-host");
      expect(hostCellMatches(ctx, m9, "special-host")).toBe(true);
    });

    it("search matches by chain, case-insensitive (S2-9)", async () => {
      const ctx = loadMonitoring();
      const m9 = await buildSearchMonitor(ctx);
      typeSearch(ctx, m9, "proxy-a");
      expect(hostCellMatches(ctx, m9, "special-host")).toBe(true);
    });

    it("search matches by source ip (S2-9)", async () => {
      const ctx = loadMonitoring();
      const m9 = await buildSearchMonitor(ctx);
      typeSearch(ctx, m9, "10.0.0.9");
      expect(hostCellMatches(ctx, m9, "special-host")).toBe(true);
    });

    it("search does NOT match JSON keys like 'metadata' (S2-9)", async () => {
      const ctx = loadMonitoring();
      const m9 = await buildSearchMonitor(ctx);
      typeSearch(ctx, m9, "metadata");
      expect(hostCellMatches(ctx, m9, "special-host")).toBe(false);
    });
  });

  // audit 9.1: Closed tab renders NO per-row Close button
  describe("audit 9.1: Closed tab", () => {
    it("Closed-tab toggle button is rendered (9.1)", async () => {
      const ctx = loadMonitoring();
      let a91conns = [conn("live1", "10.0.0.5", "h1")];
      ctx.__test.setClashGet(() =>
        Promise.resolve({
          status: "ok",
          body: JSON.stringify({
            connections: a91conns,
            downloadTotal: 0,
            uploadTotal: 0,
          }),
        }),
      );
      const m91 = ctx.__moduleExports.buildMonitoring();
      await m91.poll();
      a91conns = [];
      await m91.poll();
      const closedTabBtn = ctx.__test.find(
        m91.node,
        (n: any) =>
          n.tag === "button" && (n.textContent || "").indexOf("Closed") >= 0,
      );
      expect(!!closedTabBtn).toBe(true);
    });

    it("Closed tab renders NO per-row Close button (9.1)", async () => {
      const ctx = loadMonitoring();
      let a91conns = [conn("live1", "10.0.0.5", "h1")];
      ctx.__test.setClashGet(() =>
        Promise.resolve({
          status: "ok",
          body: JSON.stringify({
            connections: a91conns,
            downloadTotal: 0,
            uploadTotal: 0,
          }),
        }),
      );
      const m91 = ctx.__moduleExports.buildMonitoring();
      await m91.poll();
      a91conns = [];
      await m91.poll();
      const closedTabBtn = ctx.__test.find(
        m91.node,
        (n: any) =>
          n.tag === "button" && (n.textContent || "").indexOf("Closed") >= 0,
      );
      closedTabBtn.attrs.click();
      const closeBtnsInClosedTab = ctx.__test.findAll(m91.node, isRowCloseBtn);
      expect(closeBtnsInClosedTab.length).toBe(0);
    });

    it("closed rows carry the 'closed' class (9.6)", async () => {
      const ctx = loadMonitoring();
      let a91conns = [conn("live1", "10.0.0.5", "h1")];
      ctx.__test.setClashGet(() =>
        Promise.resolve({
          status: "ok",
          body: JSON.stringify({
            connections: a91conns,
            downloadTotal: 0,
            uploadTotal: 0,
          }),
        }),
      );
      const m91 = ctx.__moduleExports.buildMonitoring();
      await m91.poll();
      a91conns = [];
      await m91.poll();
      // Switch to Closed tab so closed rows are rendered
      const closedTabBtn = ctx.__test.find(
        m91.node,
        (n: any) =>
          n.tag === "button" && (n.textContent || "").indexOf("Closed") >= 0,
      );
      closedTabBtn.attrs.click();
      const closedRow = ctx.__test.find(
        m91.node,
        (n: any) =>
          n.tag === "tr" &&
          n.attrs &&
          /(^|\s)closed(\s|$)/.test(n.attrs.class || ""),
      );
      expect(!!closedRow).toBe(true);
    });

    it("a failed per-row DELETE does NOT show unreachable (9.1)", async () => {
      const ctx = loadMonitoring();
      const a91bConns = [conn("x9", "10.0.0.6", "gone-soon")];
      ctx.__test.setClashGet(() =>
        Promise.resolve({
          status: "ok",
          body: JSON.stringify({
            connections: a91bConns,
            downloadTotal: 0,
            uploadTotal: 0,
          }),
        }),
      );
      ctx.__test.setClashMutate(() =>
        Promise.reject(new Error("404 not found")),
      );
      const m91b = ctx.__moduleExports.buildMonitoring();
      await m91b.poll();
      const rowBtn = ctx.__test.find(m91b.node, isRowCloseBtn);
      await rowBtn.attrs.click();
      expect(m91b.node.textContent.indexOf("Connections are unavailable")).toBe(
        -1,
      );
    });

    it("a failed per-row DELETE keeps the table mounted (9.1)", async () => {
      const ctx = loadMonitoring();
      const a91bConns = [conn("x9", "10.0.0.6", "gone-soon")];
      ctx.__test.setClashGet(() =>
        Promise.resolve({
          status: "ok",
          body: JSON.stringify({
            connections: a91bConns,
            downloadTotal: 0,
            uploadTotal: 0,
          }),
        }),
      );
      ctx.__test.setClashMutate(() =>
        Promise.reject(new Error("404 not found")),
      );
      const m91b = ctx.__moduleExports.buildMonitoring();
      await m91b.poll();
      const rowBtn = ctx.__test.find(m91b.node, isRowCloseBtn);
      await rowBtn.attrs.click();
      expect(!!ctx.__test.find(m91b.node, (n: any) => n.tag === "table")).toBe(
        true,
      );
    });
  });

  // MON-1: "Close all" failure re-polls, does NOT wipe the table
  describe("MON-1: Close all failure re-polls", () => {
    it("Close all button is rendered (MON-1)", async () => {
      const ctx = loadMonitoring();
      const monConns = [conn("z1", "10.0.0.9", "still-here")];
      ctx.__test.setClashGet(() =>
        Promise.resolve({
          status: "ok",
          body: JSON.stringify({
            connections: monConns,
            downloadTotal: 0,
            uploadTotal: 0,
          }),
        }),
      );
      ctx.__test.setClashMutate(() =>
        Promise.reject(new Error("nothing to close")),
      );
      const mAll = ctx.__moduleExports.buildMonitoring();
      await mAll.poll();
      const closeAllBtn = ctx.__test.find(mAll.node, isCloseAllBtn);
      expect(!!closeAllBtn).toBe(true);
    });

    it("a failed Close all does NOT show unreachable (MON-1)", async () => {
      const ctx = loadMonitoring();
      const monConns = [conn("z1", "10.0.0.9", "still-here")];
      ctx.__test.setClashGet(() =>
        Promise.resolve({
          status: "ok",
          body: JSON.stringify({
            connections: monConns,
            downloadTotal: 0,
            uploadTotal: 0,
          }),
        }),
      );
      ctx.__test.setClashMutate(() =>
        Promise.reject(new Error("nothing to close")),
      );
      const mAll = ctx.__moduleExports.buildMonitoring();
      await mAll.poll();
      const closeAllBtn = ctx.__test.find(mAll.node, isCloseAllBtn);
      await closeAllBtn.attrs.click();
      expect(mAll.node.textContent.indexOf("Connections are unavailable")).toBe(
        -1,
      );
    });

    it("a failed Close all keeps the table mounted (MON-1)", async () => {
      const ctx = loadMonitoring();
      const monConns = [conn("z1", "10.0.0.9", "still-here")];
      ctx.__test.setClashGet(() =>
        Promise.resolve({
          status: "ok",
          body: JSON.stringify({
            connections: monConns,
            downloadTotal: 0,
            uploadTotal: 0,
          }),
        }),
      );
      ctx.__test.setClashMutate(() =>
        Promise.reject(new Error("nothing to close")),
      );
      const mAll = ctx.__moduleExports.buildMonitoring();
      await mAll.poll();
      const closeAllBtn = ctx.__test.find(mAll.node, isCloseAllBtn);
      await closeAllBtn.attrs.click();
      expect(!!ctx.__test.find(mAll.node, (n: any) => n.tag === "table")).toBe(
        true,
      );
    });
  });

  // audit 9.2: a vanished filter device resets the filter to "all"
  describe("audit 9.2: vanished device resets filter", () => {
    it("rows are filtered to the selected device (9.2)", async () => {
      const ctx = loadMonitoring();
      const a92conns = [
        conn("p", "10.0.0.7", "dev-a"),
        conn("q", "10.0.0.8", "dev-b"),
      ];
      ctx.__test.setClashGet(() =>
        Promise.resolve({
          status: "ok",
          body: JSON.stringify({
            connections: a92conns,
            downloadTotal: 0,
            uploadTotal: 0,
          }),
        }),
      );
      ctx.__test.setClashMutate(() => Promise.resolve({ status: "ok" }));
      const m92 = ctx.__moduleExports.buildMonitoring();
      await m92.poll();
      const sel92 = ctx.__test.find(m92.node, isSelect);
      sel92.attrs.change({ target: { value: "10.0.0.7" } });
      const devACells = ctx.__test.findAll(
        m92.node,
        (n: any) =>
          n.tag === "td" && (n.textContent || "").indexOf("dev-a") >= 0,
      );
      const devBCells = ctx.__test.findAll(
        m92.node,
        (n: any) =>
          n.tag === "td" && (n.textContent || "").indexOf("dev-b") >= 0,
      );
      expect(devACells.length).toBeGreaterThanOrEqual(1);
      expect(devBCells.length).toBe(0);
    });

    it("filter resets to all when its device vanishes (9.2 — dev-b now visible)", async () => {
      const ctx = loadMonitoring();
      let a92conns = [
        conn("p", "10.0.0.7", "dev-a"),
        conn("q", "10.0.0.8", "dev-b"),
      ];
      ctx.__test.setClashGet(() =>
        Promise.resolve({
          status: "ok",
          body: JSON.stringify({
            connections: a92conns,
            downloadTotal: 0,
            uploadTotal: 0,
          }),
        }),
      );
      ctx.__test.setClashMutate(() => Promise.resolve({ status: "ok" }));
      const m92 = ctx.__moduleExports.buildMonitoring();
      await m92.poll();
      const sel92 = ctx.__test.find(m92.node, isSelect);
      sel92.attrs.change({ target: { value: "10.0.0.7" } });
      a92conns = [conn("q", "10.0.0.8", "dev-b")];
      await m92.poll();
      const devBCells = ctx.__test.findAll(
        m92.node,
        (n: any) =>
          n.tag === "td" && (n.textContent || "").indexOf("dev-b") >= 0,
      );
      expect(devBCells.length).toBeGreaterThanOrEqual(1);
    });

    it("filter reset prevents a stranded zero-row table (9.2)", async () => {
      const ctx = loadMonitoring();
      let a92conns = [
        conn("p", "10.0.0.7", "dev-a"),
        conn("q", "10.0.0.8", "dev-b"),
      ];
      ctx.__test.setClashGet(() =>
        Promise.resolve({
          status: "ok",
          body: JSON.stringify({
            connections: a92conns,
            downloadTotal: 0,
            uploadTotal: 0,
          }),
        }),
      );
      ctx.__test.setClashMutate(() => Promise.resolve({ status: "ok" }));
      const m92 = ctx.__moduleExports.buildMonitoring();
      await m92.poll();
      const sel92 = ctx.__test.find(m92.node, isSelect);
      sel92.attrs.change({ target: { value: "10.0.0.7" } });
      a92conns = [conn("q", "10.0.0.8", "dev-b")];
      await m92.poll();
      const noConnCell = ctx.__test.find(
        m92.node,
        (n: any) =>
          n.tag === "td" &&
          (n.textContent || "").indexOf("No active connections") >= 0,
      );
      expect(noConnCell).toBeNull();
    });
  });

  // audit 9.6: selected Active/Closed tab gets cbi-button-active
  describe("audit 9.6: tab selection CSS class", () => {
    it("Active tab is marked selected by default (9.6)", async () => {
      const ctx = loadMonitoring();
      ctx.__test.setClashGet(() =>
        Promise.resolve({
          status: "ok",
          body: JSON.stringify({
            connections: [],
            downloadTotal: 0,
            uploadTotal: 0,
          }),
        }),
      );
      const m96 = ctx.__moduleExports.buildMonitoring();
      await m96.poll();
      const btnActive96 = ctx.__test.find(
        m96.node,
        (n: any) =>
          n.tag === "button" && (n.textContent || "").indexOf("Active") >= 0,
      );
      const btnClosed96 = ctx.__test.find(
        m96.node,
        (n: any) =>
          n.tag === "button" && (n.textContent || "").indexOf("Closed") >= 0,
      );
      expect(/cbi-button-active/.test(btnActive96.attrs.class || "")).toBe(
        true,
      );
      expect(/cbi-button-active/.test(btnClosed96.attrs.class || "")).toBe(
        false,
      );
    });

    it("selected class moves to Closed after toggle (9.6)", async () => {
      const ctx = loadMonitoring();
      ctx.__test.setClashGet(() =>
        Promise.resolve({
          status: "ok",
          body: JSON.stringify({
            connections: [],
            downloadTotal: 0,
            uploadTotal: 0,
          }),
        }),
      );
      const m96 = ctx.__moduleExports.buildMonitoring();
      await m96.poll();
      const btnActive96 = ctx.__test.find(
        m96.node,
        (n: any) =>
          n.tag === "button" && (n.textContent || "").indexOf("Active") >= 0,
      );
      const btnClosed96 = ctx.__test.find(
        m96.node,
        (n: any) =>
          n.tag === "button" && (n.textContent || "").indexOf("Closed") >= 0,
      );
      btnClosed96.attrs.click();
      expect(/cbi-button-active/.test(btnClosed96.attrs.class || "")).toBe(
        true,
      );
      expect(/cbi-button-active/.test(btnActive96.attrs.class || "")).toBe(
        false,
      );
    });
  });

  // The connection row grew from "host / device / chain / down / up" to the
  // forkop column set. Each of these cells is a separate lookup path in
  // monitoring.js (endpoint / networkOf / routeOf / durationOf / sourceOf), so
  // a row that silently loses one of them is a real regression.
  describe("connection row columns", () => {
    async function rowFor(ctx: any, c: any) {
      ctx.__test.setClashGet(() =>
        Promise.resolve({
          status: "ok",
          body: JSON.stringify({ connections: [c] }),
        }),
      );
      const m = ctx.__moduleExports.buildMonitoring();
      await m.poll();
      return ctx.__test.find(
        m.node,
        (n: any) =>
          n.tag === "tr" && (n.textContent || "").indexOf("ex.com") >= 0,
      );
    }
    const CONN = {
      id: "c1",
      start: new Date(Date.now() - 65000).toISOString(),
      metadata: {
        sourceIP: "10.0.0.5",
        host: "ex.com",
        destinationPort: 8080,
        network: "tcp",
      },
      chains: ["node-a", "GW"],
      download: 0,
      upload: 0,
    };

    it("host cell carries a non-443 port", async () => {
      const row = await rowFor(loadMonitoring(), CONN);
      expect(
        (row.textContent || "").indexOf("ex.com:8080"),
      ).toBeGreaterThanOrEqual(0);
    });

    it("port 443 is dropped as noise", async () => {
      const ctx = loadMonitoring();
      const row = await rowFor(ctx, {
        ...CONN,
        metadata: { ...CONN.metadata, destinationPort: 443 },
      });
      expect((row.textContent || "").indexOf("ex.com:")).toBe(-1);
    });

    // Every string in this table is attacker-supplied: metadata.host is the SNI
    // / Host header of a connection ANY LAN client can open, and sourceIP's name
    // is a DHCP hostname — the classic OpenWrt injection vector. A bare string
    // child goes through innerHTML in LuCI's dom.append(), so the guard is the
    // SHAPE (nothing reached _html), not the rendered text.
    it("XSS: a hostile host and DHCP hostname are text, not markup", async () => {
      const EVIL = '<img src=x onerror="alert(1)">';
      const ctx = loadMonitoring();
      ctx.__test.setClashGet(() =>
        Promise.resolve({
          status: "ok",
          body: JSON.stringify({
            connections: [
              {
                ...CONN,
                metadata: {
                  ...CONN.metadata,
                  host: EVIL,
                  sourceIP: "10.0.0.9",
                },
              },
            ],
          }),
        }),
      );
      const m = ctx.__moduleExports.buildMonitoring();
      await m.poll();

      const spans: any[] = [];
      (function walk(n: any) {
        if (!n) return;
        // Only the connection-row cells; the tab buttons carry literal labels,
        // and a literal through innerHTML is not a vector.
        if (n.tag === "span" && /sb-mon-(val|src)/.test(n.attrs?.class || ""))
          spans.push(n);
        for (const k of n.children || []) walk(k);
      })(m.node);

      expect(spans.length).toBeGreaterThan(0);
      for (const sp of spans) expect(sp._html).toBe("");
      const host = spans.find((sp) => (sp.textContent || "").includes(EVIL));
      expect(host).toBeTruthy();
    });

    it("route is the LAST chain entry (the group), not the leaf node", async () => {
      const row = await rowFor(loadMonitoring(), CONN);
      const route = ctx_findClass(row, "sb-mon-route");
      expect(route?.textContent).toBe("GW");
    });

    it("network and duration are rendered", async () => {
      const row = await rowFor(loadMonitoring(), CONN);
      expect(ctx_findClass(row, "sb-mon-net")?.textContent).toBe("tcp");
      // start is 65s ago -> "1:05"
      expect((row.textContent || "").indexOf("1:05")).toBeGreaterThanOrEqual(0);
    });

    function ctx_findClass(node: any, cls: string): any {
      if (
        node?.attrs &&
        new RegExp(`\\b${cls}\\b`).test(node.attrs.class || "")
      )
        return node;
      for (const kid of node?.children || []) {
        const hit = ctx_findClass(kid, cls);
        if (hit) return hit;
      }
      return null;
    }
  });

  // Pause is the whole point of the pause button: the table the user is reading
  // must stop moving. A poll that still ingests while paused would keep rows
  // appearing and disappearing under the cursor.
  it("paused poll() ingests nothing", async () => {
    const ctx = loadMonitoring();
    let served = [conn("a", "10.0.0.1", "first")];
    ctx.__test.setClashGet(() =>
      Promise.resolve({
        status: "ok",
        body: JSON.stringify({ connections: served }),
      }),
    );
    const m = ctx.__moduleExports.buildMonitoring();
    await m.poll();
    m.setPaused(true);
    served = [conn("b", "10.0.0.2", "second")];
    await m.poll();
    expect(m.node.textContent.indexOf("first")).toBeGreaterThanOrEqual(0);
    expect(m.node.textContent.indexOf("second")).toBe(-1);
    m.setPaused(false);
    await m.poll();
    expect(m.node.textContent.indexOf("second")).toBeGreaterThanOrEqual(0);
  });

  // Pausing must FREEZE the view, not DROP data: a connection that opens (and
  // even closes) while paused would otherwise never be seen at all. The newest
  // payload is parked and replayed on resume.
  it("pause parks the payload — a connection born while paused shows on resume", async () => {
    const ctx = loadMonitoring();
    let served = [conn("a", "10.0.0.1", "first")];
    ctx.__test.setClashGet(() =>
      Promise.resolve({
        status: "ok",
        body: JSON.stringify({ connections: served }),
      }),
    );
    const m = ctx.__moduleExports.buildMonitoring();
    await m.poll();
    m.setPaused(true);
    served = [conn("a", "10.0.0.1", "first"), conn("b", "10.0.0.2", "second")];
    await m.poll(); // arrives while paused -> parked, not painted
    expect(m.node.textContent.indexOf("second")).toBe(-1);
    m.setPaused(false); // NO new poll: the parked payload must be applied
    expect(m.node.textContent.indexOf("second")).toBeGreaterThanOrEqual(0);
  });

  // Route shows the human name of the outbound (rpcd outbound_meta side-car),
  // not the content-hash tag sing-box routes on.
  it("route resolves the outbound tag to its human name", async () => {
    const ctx = loadMonitoring();
    ctx.__test.setOutboundMeta(() =>
      Promise.resolve({ meta: { sub__ab12: { name: "Amsterdam 01" } } }),
    );
    ctx.__test.setClashGet(() =>
      Promise.resolve({
        status: "ok",
        body: JSON.stringify({
          connections: [conn("r1", "10.0.0.1", "ex.com", ["sub__ab12"])],
        }),
      }),
    );
    const m = ctx.__moduleExports.buildMonitoring();
    m.start();
    await m.poll();
    await m.poll();
    m.stop();
    expect(m.node.textContent.indexOf("Amsterdam 01")).toBeGreaterThanOrEqual(
      0,
    );
    expect(m.node.textContent.indexOf("sub__ab12")).toBe(-1);
  });

  it("an unmapped tag falls back to the raw tag", async () => {
    const ctx = loadMonitoring();
    ctx.__test.setClashGet(() =>
      Promise.resolve({
        status: "ok",
        body: JSON.stringify({
          connections: [conn("r2", "10.0.0.1", "ex.com", ["direct"])],
        }),
      }),
    );
    const m = ctx.__moduleExports.buildMonitoring();
    await m.poll();
    expect(m.node.textContent.indexOf("direct")).toBeGreaterThanOrEqual(0);
  });

  // The duration column must advance between polls; without its own tick it sat
  // frozen at whatever the last payload painted.
  it("Time ticks without a new poll", async () => {
    const ctx = loadMonitoring();
    const start = new Date(Date.now() - 65000).toISOString();
    ctx.__test.setClashGet(() =>
      Promise.resolve({
        status: "ok",
        body: JSON.stringify({
          connections: [
            {
              id: "t1",
              start,
              metadata: { sourceIP: "10.0.0.1", host: "ex.com" },
            },
          ],
        }),
      }),
    );
    const m = ctx.__moduleExports.buildMonitoring();
    await m.poll();
    expect(m.node.textContent.indexOf("1:05")).toBeGreaterThanOrEqual(0);
    const real = Date.now;
    Date.now = () => real() + 5000;
    try {
      m._tickTimes();
      expect(m.node.textContent.indexOf("1:10")).toBeGreaterThanOrEqual(0);
    } finally {
      Date.now = real;
    }
  });

  it("Time is frozen while paused", async () => {
    const ctx = loadMonitoring();
    const start = new Date(Date.now() - 65000).toISOString();
    ctx.__test.setClashGet(() =>
      Promise.resolve({
        status: "ok",
        body: JSON.stringify({
          connections: [
            {
              id: "t1",
              start,
              metadata: { sourceIP: "10.0.0.1", host: "ex.com" },
            },
          ],
        }),
      }),
    );
    const m = ctx.__moduleExports.buildMonitoring();
    await m.poll();
    m.setPaused(true);
    const real = Date.now;
    Date.now = () => real() + 5000;
    try {
      m._tickTimes();
      expect(m.node.textContent.indexOf("1:05")).toBeGreaterThanOrEqual(0);
      expect(m.node.textContent.indexOf("1:10")).toBe(-1);
    } finally {
      Date.now = real;
    }
  });

  // Closed connections never come back, so the map only grows. Uncapped, an
  // hour on a busy LAN buries the repaint under tens of thousands of dead rows.
  it("the closed list is capped at 300, newest kept", async () => {
    const ctx = loadMonitoring();
    let served: any[] = [];
    ctx.__test.setClashGet(() =>
      Promise.resolve({
        status: "ok",
        body: JSON.stringify({ connections: served }),
      }),
    );
    const m = ctx.__moduleExports.buildMonitoring();
    for (let i = 0; i < 320; i++) {
      served = [conn(`c${i}`, "10.0.0.1", `host${i}`)];
      await m.poll(); // c{i} appears
      served = [];
      await m.poll(); // c{i} closes
    }
    const closedBtn = ctx.__test.find(m.node, isTabBtn("closed"));
    expect(tabCount(closedBtn)).toBe("300");
  });

  it("byte columns use the dashboard's decimal scale, not a 1024 one", async () => {
    // The two tabs used to disagree: the dashboard divided by 1000 and printed
    // "1 MB", the table divided by 1024 and printed "976.6KB" for the same
    // number. 1e6 is the discriminator — only a 1024 divisor keeps it in KB.
    const ctx = loadMonitoring();
    ctx.__test.setClashGet(() =>
      Promise.resolve({
        status: "ok",
        body: JSON.stringify({
          connections: [
            {
              ...conn("c1", "10.0.0.5", "hostA"),
              download: 1_000_000,
              upload: 0,
            },
          ],
        }),
      }),
    );
    const m = ctx.__moduleExports.buildMonitoring();
    await m.poll();
    expect(m.node.textContent.indexOf("1 MB")).toBeGreaterThanOrEqual(0);
    expect(m.node.textContent.indexOf("KB")).toBe(-1);
  });
});
