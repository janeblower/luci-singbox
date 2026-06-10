#!/bin/sh
# tests/test_monitoring_js.sh — Node harness for tabs/monitoring.js.
# Loads the LuCI view fragment into a vm sandbox (mirrors tests/test_json_import.sh)
# and asserts async-safety + DOM-stability of the connection monitor.
set -e
cd "$(dirname "$0")/.."

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available" >&2
  exit 0
fi

JS=luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/tabs/monitoring.js
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/run.js" <<'NODE'
const fs = require('fs');
const vm = require('vm');

const src = fs.readFileSync(process.argv[2], 'utf8');
const body = src
  .replace(/^'use strict';\s*/, '')
  .replace(/^'require [^']+';\s*/gm, '')
  .replace(/return L\.Class\.extend\((\{[\s\S]*\})\);?\s*$/, '__moduleExports = $1;');

// --- minimal DOM/LuCI stubs -------------------------------------------------
let intervalId = 0;
const intervals = {};      // id -> { fn, ms }
const timeouts = {};       // id -> fn
let timeoutId = 0;

function makeEl(tag) {
  const el = {
    tag: tag, children: [], attrs: {}, _text: '', isConnected: true,
    appendChild: function (c) { if (c) this.children.push(c); return c; },
    set innerHTML(v) { if (v === '') this.children = []; },
    get innerHTML() { return ''; },
    set textContent(v) { this._text = String(v); this.children = []; },
    get textContent() {
      // Recursively collect text so the test can assert on rendered strings.
      let t = this._text || '';
      for (const c of this.children) t += (c && c.textContent) || '';
      return t;
    },
    scrollTop: 0,
    querySelectorAll: function () { return []; },
  };
  return el;
}
// E(tag, attrsOrChildren, children) — accepts the LuCI calling shapes used here.
function E(tag, a, c) {
  const el = makeEl(tag);
  let kids = c;
  if (a && typeof a === 'object' && !Array.isArray(a) && a.tag === undefined) el.attrs = a;
  else kids = a;
  function add(x) {
    if (x == null) return;
    if (Array.isArray(x)) { x.forEach(add); return; }
    if (typeof x === 'string') { el._text += x; return; }
    el.children.push(x);
  }
  add(kids);
  return el;
}

let clashGetImpl = () => Promise.resolve({ status: 'ok', body: '{"connections":[]}' });
let clashMutateImpl = () => Promise.resolve({ status: 'ok' });

const sandbox = {
  __moduleExports: null,
  _: (s) => s,
  E: E,
  L: { Class: { extend: (o) => o } },
  ui: { createHandlerFn: (ctx, fn) => fn },
  document: { visibilityState: 'visible', addEventListener(){}, removeEventListener(){} },
  window: { scrollY: 0, scrollTo(){}, addEventListener(){}, removeEventListener(){} },
  setInterval: (fn, ms) => { const id = ++intervalId; intervals[id] = { fn, ms }; return id; },
  clearInterval: (id) => { delete intervals[id]; },
  setTimeout: (fn) => { const id = ++timeoutId; timeouts[id] = fn; return id; },
  clearTimeout: (id) => { delete timeouts[id]; },
  Math: Math, Object: Object, Array: Array, JSON: JSON, Promise: Promise,
  Number: Number, String: String, console: console,
  SbRpc: {
    callClashGet:    (...a) => clashGetImpl(...a),
    callClashMutate: (...a) => clashMutateImpl(...a),
    callDhcpLeases:  () => Promise.resolve({ leases: [] }),
  },
  __test: {
    setClashGet: (fn) => { clashGetImpl = fn; },
    setClashMutate: (fn) => { clashMutateImpl = fn; },
    intervals, timeouts,
    fireInterval: (id) => intervals[id] && intervals[id].fn(),
    fireAllTimeouts: () => { Object.keys(timeouts).forEach(k => { const f = timeouts[k]; delete timeouts[k]; f(); }); },
    // Generic DOM walker so tests can locate rendered elements WITHOUT adding
    // any test-only hooks to the production source. find(root, pred) returns the
    // first descendant (or root) matching pred; findAll collects every match.
    find: function (n, pred) {
      if (!n) return null;
      if (pred(n)) return n;
      var kids = n.children || [];
      for (var i = 0; i < kids.length; i++) {
        var r = this.find(kids[i], pred);
        if (r) return r;
      }
      return null;
    },
    findAll: function (n, pred, out) {
      out = out || [];
      if (!n) return out;
      if (pred(n)) out.push(n);
      var kids = n.children || [];
      for (var i = 0; i < kids.length; i++) this.findAll(kids[i], pred, out);
      return out;
    },
  },
};
const ctx = vm.createContext(sandbox);
vm.runInContext('(function(){' + body + '})();', ctx, { filename: 'monitoring.js' });

const Mon = ctx.__moduleExports;
let failures = 0;
function ok(label, cond) {
  if (cond) console.log('  PASS:', label);
  else { console.log('  FAIL:', label); failures++; }
}

// --- S2-1: poll() must not reject when the RPC rejects ----------------------
(async function () {
  ctx.__test.setClashGet(() => Promise.reject(new Error('ubus down')));
  const m = Mon.buildMonitoring();
  let rejected = false;
  await m.poll().catch(() => { rejected = true; });
  ok('poll() swallows RPC rejection (S2-1)', rejected === false);
  ok('poll() shows unreachable message on failure (S2-1)',
     m.node.textContent.indexOf('Clash API unreachable') >= 0);

  // --- S2-2: the interval self-cancels once root detaches ------------------
  ctx.__test.setClashGet(() => Promise.resolve({ status:'ok', body:'{"connections":[]}' }));
  ctx.__test.setClashMutate(() => Promise.resolve({ status:'ok' }));
  const m2 = Mon.buildMonitoring();
  m2.start();
  const ids = Object.keys(ctx.__test.intervals);
  ok('start() registers exactly one interval (S2-2)', ids.length === 1);
  // Simulate SPA navigation: the node is removed from the DOM.
  m2.node.isConnected = false;
  ctx.__test.fireInterval(ids[0]);     // the tick that runs after we navigated away
  ok('interval clears itself when root detached (S2-2)',
     Object.keys(ctx.__test.intervals).length === 0);

  // --- S2-3: stop() clears a pending search-debounce timer -----------------
  const m3 = Mon.buildMonitoring();
  m3.start();
  // Simulate a keystroke: schedule a debounced search.
  m3.debouncedSearch('foo', function () {});
  const tIds = Object.keys(ctx.__test.timeouts);
  ok('debouncedSearch scheduled a timeout (S2-3)', tIds.length >= 1);
  m3.stop();
  ok('stop() cleared the debounce timer (S2-3)',
     Object.keys(ctx.__test.timeouts).length === 0);

  if (failures) { console.error('test_monitoring_js: ' + failures + ' failure(s)'); process.exit(1); }
  console.log('OK');
})().catch((e) => { console.error('harness error', e); process.exit(1); });
NODE

node "$TMP/run.js" "$JS"
