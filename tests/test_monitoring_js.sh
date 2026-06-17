#!/bin/sh
# tests/test_monitoring_js.sh — Node harness for tabs/monitoring.js.
# Loads the LuCI view fragment into a vm sandbox (mirrors tests/test_json_import.sh)
# and asserts async-safety + DOM-stability of the connection monitor.
set -e
. "$(dirname "$0")/lib/sb_helpers.sh"
cd "$(dirname "$0")/.."

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available" >&2
  exit 0
fi

JS=${SB_VIEW}/tabs/monitoring.js
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
    // monitoring.js sets el.className to toggle the selected-tab class (audit
    // 9.6); mirror it into attrs.class so the DOM walker/tests can read it the
    // same way they read the class passed to E().
    set className(v) { this.attrs['class'] = String(v); },
    get className() { return this.attrs['class'] || ''; },
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

  // --- S2-4: repaint preserves the search-input element across polls -------
  ctx.__test.setClashGet(() => Promise.resolve({ status:'ok',
    body: JSON.stringify({ connections: [], downloadTotal: 0, uploadTotal: 0 }) }));
  const m4 = Mon.buildMonitoring();
  const isSearch = (n) => n.tag === 'input' && n.attrs && n.attrs.type === 'search';
  await m4.poll();
  const search1 = ctx.__test.find(m4.node, isSearch);
  await m4.poll();
  const search2 = ctx.__test.find(m4.node, isSearch);
  ok('search input is rendered (S2-4)', !!search1);
  ok('search input survives repaint — same node object (S2-4)',
     search1 && search1 === search2);

  // --- S2-6: handlers act on the CURRENT poll's data, not a captured one ----
  // Regression guard for the original repaint(data) staleness. Fails against
  // the pre-Task-4 source (toolbar/handlers captured `data`); green after.
  let s6conns = [{ id: 'a', metadata: { sourceIP: '10.0.0.1', host: 'old' }, chains: [] }];
  ctx.__test.setClashGet(() => Promise.resolve({ status:'ok',
    body: JSON.stringify({ connections: s6conns, downloadTotal: 0, uploadTotal: 0 }) }));
  const m6 = Mon.buildMonitoring();
  await m6.poll();                                  // renders row for conn 'a'
  s6conns = [{ id: 'b', metadata: { sourceIP: '10.0.0.2', host: 'new' }, chains: [] }];
  await m6.poll();                                  // tbody now holds conn 'b' only
  const deletes = [];
  ctx.__test.setClashMutate((method, path) => { deletes.push(path); return Promise.resolve({ status:'ok' }); });
  // Both the per-row Close and the toolbar "Close all" carry cbi-button-remove;
  // the per-row button deletes /connections/<id>, "Close all" deletes
  // /connections. Click every such button and assert the ROW delete targeted b.
  const isCloseBtn = (n) => n.tag === 'button' &&
    n.attrs && /cbi-button-remove/.test(n.attrs['class'] || '') && typeof n.attrs.click === 'function';
  const closeBtns = ctx.__test.findAll(m6.node, isCloseBtn);
  ok('a per-row Close button is rendered for current data (S2-6)', closeBtns.length >= 1);
  closeBtns.forEach(b => b.attrs.click());
  ok('a row Close acts on latest connection id b, not stale a (S2-6)',
     deletes.indexOf('/connections/b') >= 0 && deletes.indexOf('/connections/a') < 0);

  // Device filter must apply to the CURRENT set. The decisive stale-closure
  // probe: capture the device-<select> change handler that exists after the
  // FIRST poll, fire ANOTHER poll, then invoke the CAPTURED handler. In the
  // original source that handler closed over poll #1's `data`, so filtering to
  // conn 'b's device (absent from poll #1) rendered zero rows. The Task-4
  // handler instead sets state.filterDevice + updateRows() which reads
  // curConns() live, so conn 'b' renders.
  const isSelect = (n) => n.tag === 'select' && n.attrs && n.attrs.change;
  let s7conns = [{ id: 'c', metadata: { sourceIP: '10.0.0.1', host: 'first-only' }, chains: [] }];
  ctx.__test.setClashGet(() => Promise.resolve({ status:'ok',
    body: JSON.stringify({ connections: s7conns, downloadTotal: 0, uploadTotal: 0 }) }));
  const m7 = Mon.buildMonitoring();
  await m7.poll();                                          // poll #1: conn 'c'
  const selHandler = ctx.__test.find(m7.node, isSelect).attrs.change;  // capture
  s7conns = [{ id: 'd', metadata: { sourceIP: '10.0.0.2', host: 'second-only' }, chains: [] }];
  await m7.poll();                                          // poll #2: conn 'd'
  ok('captured device <select> handler exists (S2-6)', typeof selHandler === 'function');
  selHandler({ target: { value: '10.0.0.2' } });            // fire the OLD handler
  const hostCells = ctx.__test.findAll(m7.node,
    (n) => n.tag === 'td' && (n.textContent || '').indexOf('second-only') >= 0);
  ok('captured handler filters the CURRENT set, not the poll it was built in (S2-6)',
     hostCells.length >= 1);

  // --- S2-9: search matches host/chain/source, NOT raw JSON keys ----------
  const s9conn = { id: 'q', metadata: { sourceIP: '10.0.0.9', host: 'special-host' },
                   chains: ['proxy-A'] };
  ctx.__test.setClashGet(() => Promise.resolve({ status:'ok',
    body: JSON.stringify({ connections: [s9conn], downloadTotal: 0, uploadTotal: 0 }) }));
  const m9 = Mon.buildMonitoring();
  await m9.poll();
  function typeSearch(term) {
    const inp = ctx.__test.find(m9.node, (n) =>
      n.tag === 'input' && n.attrs && n.attrs.type === 'search');
    inp.attrs.keyup({ target: { value: term } });   // schedules the debounce
    ctx.__test.fireAllTimeouts();                    // flush the 200ms setTimeout
  }
  function hostCellMatches(text) {
    return ctx.__test.findAll(m9.node,
      (n) => n.tag === 'td' && (n.textContent || '').indexOf(text) >= 0).length >= 1;
  }
  typeSearch('special-host');
  ok('search matches by host (S2-9)', hostCellMatches('special-host'));
  typeSearch('proxy-a');
  ok('search matches by chain, case-insensitive (S2-9)', hostCellMatches('special-host'));
  typeSearch('10.0.0.9');
  ok('search matches by source ip (S2-9)', hostCellMatches('special-host'));
  // A JSON-structural token must NOT match: JSON.stringify(c) would contain
  // "metadata"/"sourceIP"; the precomputed hay must not.
  typeSearch('metadata');
  ok('search does NOT match JSON keys like metadata (S2-9)', !hostCellMatches('special-host'));

  // --- audit 9.1: Closed tab renders NO per-row Close button ----------------
  // A connection that closes between polls moves into state.closed and is shown
  // in the Closed tab. It must NOT carry a Close button: deleting an id that no
  // longer exists previously tripped showUnreachable and wiped the whole table.
  // Per-row Close buttons read exactly "Close"; the toolbar button reads
  // "Close all" — both carry cbi-button-remove, so match on the precise label.
  const isRowCloseBtn = (n) => n.tag === 'button' &&
    n.attrs && /cbi-button-remove/.test(n.attrs['class'] || '') &&
    typeof n.attrs.click === 'function' && (n.textContent || '') === 'Close';
  let a91conns = [{ id: 'live1', metadata: { sourceIP: '10.0.0.5', host: 'h1' }, chains: [] }];
  ctx.__test.setClashGet(() => Promise.resolve({ status:'ok',
    body: JSON.stringify({ connections: a91conns, downloadTotal: 0, uploadTotal: 0 }) }));
  const m91 = Mon.buildMonitoring();
  await m91.poll();                                   // conn live1 active
  a91conns = [];                                      // it closed -> moves to state.closed
  await m91.poll();
  // Active tab still shows a Close button for current (now zero) conns: none here.
  const closedTabBtn = ctx.__test.find(m91.node,
    (n) => n.tag === 'button' && (n.textContent || '').indexOf('Closed') >= 0);
  ok('Closed-tab toggle button is rendered (9.1)', !!closedTabBtn);
  closedTabBtn.attrs.click();                          // switch to Closed tab
  const closeBtnsInClosedTab = ctx.__test.findAll(m91.node, isRowCloseBtn);
  ok('Closed tab renders NO per-row Close button (9.1)', closeBtnsInClosedTab.length === 0);
  // And the closed row carries the `closed` class so the fade CSS applies (9.6).
  const closedRow = ctx.__test.find(m91.node,
    (n) => n.tag === 'tr' && n.attrs && /(^|\s)closed(\s|$)/.test(n.attrs['class'] || ''));
  ok('closed rows carry the `closed` class (9.6)', !!closedRow);

  // --- audit 9.1: a per-connection DELETE failure re-polls, NOT unreachable -
  // Clicking Close on a row whose connection vanished server-side rejects the
  // DELETE. That benign failure must re-poll and keep the table, not blow it
  // away with the "Clash API unreachable" message.
  let a91bConns = [{ id: 'x9', metadata: { sourceIP: '10.0.0.6', host: 'gone-soon' }, chains: [] }];
  ctx.__test.setClashGet(() => Promise.resolve({ status:'ok',
    body: JSON.stringify({ connections: a91bConns, downloadTotal: 0, uploadTotal: 0 }) }));
  ctx.__test.setClashMutate(() => Promise.reject(new Error('404 not found')));
  const m91b = Mon.buildMonitoring();
  await m91b.poll();
  const rowBtn = ctx.__test.find(m91b.node, isRowCloseBtn);
  ok('active row has a Close button to test against (9.1)', !!rowBtn);
  await rowBtn.attrs.click();                          // DELETE rejects, then re-polls
  ok('a failed per-row DELETE does NOT show unreachable (9.1)',
     m91b.node.textContent.indexOf('Clash API unreachable') < 0);
  ok('a failed per-row DELETE keeps the table mounted (9.1)',
     !!ctx.__test.find(m91b.node, (n) => n.tag === 'table'));

  // --- MON-1: "Close all" failure re-polls, does NOT wipe the table ---------
  // Symmetric with the per-row case (9.1): a benign bulk-DELETE failure (e.g.
  // "nothing to close" / transient non-fatal clash-api response) must re-poll
  // and keep the table, not blank it with "Clash API unreachable". Only a
  // rejected poll() RPC clears the table.
  let monConns = [{ id: 'z1', metadata: { sourceIP: '10.0.0.9', host: 'still-here' }, chains: [] }];
  ctx.__test.setClashGet(() => Promise.resolve({ status:'ok',
    body: JSON.stringify({ connections: monConns, downloadTotal: 0, uploadTotal: 0 }) }));
  ctx.__test.setClashMutate(() => Promise.reject(new Error('nothing to close')));
  const mAll = Mon.buildMonitoring();
  await mAll.poll();
  const isCloseAllBtn = (n) => n.tag === 'button' &&
    n.attrs && /cbi-button-remove/.test(n.attrs['class'] || '') &&
    typeof n.attrs.click === 'function' && (n.textContent || '') === 'Close all';
  const closeAllBtn = ctx.__test.find(mAll.node, isCloseAllBtn);
  ok('Close all button is rendered (MON-1)', !!closeAllBtn);
  await closeAllBtn.attrs.click();                     // bulk DELETE rejects, then re-polls
  ok('a failed Close all does NOT show unreachable (MON-1)',
     mAll.node.textContent.indexOf('Clash API unreachable') < 0);
  ok('a failed Close all keeps the table mounted (MON-1)',
     !!ctx.__test.find(mAll.node, (n) => n.tag === 'table'));

  // --- audit 9.2: a vanished filter device resets the filter to "all" -------
  // Filter on a device, then let all its connections close. The select must not
  // strand the user on a stale IP with zero rows; the filter resets to "all".
  let a92conns = [{ id: 'p', metadata: { sourceIP: '10.0.0.7', host: 'dev-a' }, chains: [] },
                  { id: 'q', metadata: { sourceIP: '10.0.0.8', host: 'dev-b' }, chains: [] }];
  ctx.__test.setClashGet(() => Promise.resolve({ status:'ok',
    body: JSON.stringify({ connections: a92conns, downloadTotal: 0, uploadTotal: 0 }) }));
  ctx.__test.setClashMutate(() => Promise.resolve({ status:'ok' }));
  const m92 = Mon.buildMonitoring();
  await m92.poll();
  const sel92 = ctx.__test.find(m92.node, (n) => n.tag === 'select' && n.attrs && n.attrs.change);
  sel92.attrs.change({ target: { value: '10.0.0.7' } });   // filter on dev-a
  ok('rows are filtered to the selected device (9.2)',
     ctx.__test.findAll(m92.node,
       (n) => n.tag === 'td' && (n.textContent || '').indexOf('dev-a') >= 0).length >= 1 &&
     ctx.__test.findAll(m92.node,
       (n) => n.tag === 'td' && (n.textContent || '').indexOf('dev-b') >= 0).length === 0);
  a92conns = [{ id: 'q', metadata: { sourceIP: '10.0.0.8', host: 'dev-b' }, chains: [] }]; // dev-a gone
  await m92.poll();
  ok('filter resets to all when its device vanishes (9.2 — dev-b now visible)',
     ctx.__test.findAll(m92.node,
       (n) => n.tag === 'td' && (n.textContent || '').indexOf('dev-b') >= 0).length >= 1);
  ok('filter reset prevents a stranded zero-row table (9.2)',
     ctx.__test.find(m92.node,
       (n) => n.tag === 'td' && (n.textContent || '').indexOf('No connections') >= 0) === null);

  // --- audit 9.6: selected Active/Closed tab gets cbi-button-active ----------
  ctx.__test.setClashGet(() => Promise.resolve({ status:'ok',
    body: JSON.stringify({ connections: [], downloadTotal: 0, uploadTotal: 0 }) }));
  const m96 = Mon.buildMonitoring();
  await m96.poll();
  const btnActive96 = ctx.__test.find(m96.node,
    (n) => n.tag === 'button' && (n.textContent || '').indexOf('Active') >= 0);
  const btnClosed96 = ctx.__test.find(m96.node,
    (n) => n.tag === 'button' && (n.textContent || '').indexOf('Closed') >= 0);
  ok('Active tab is marked selected by default (9.6)',
     /cbi-button-active/.test(btnActive96.attrs['class'] || '') &&
     !/cbi-button-active/.test(btnClosed96.attrs['class'] || ''));
  btnClosed96.attrs.click();
  ok('selected class moves to Closed after toggle (9.6)',
     /cbi-button-active/.test(btnClosed96.attrs['class'] || '') &&
     !/cbi-button-active/.test(btnActive96.attrs['class'] || ''));

  if (failures) { console.error('test_monitoring_js: ' + failures + ' failure(s)'); process.exit(1); }
  console.log('OK');
})().catch((e) => { console.error('harness error', e); process.exit(1); });
NODE

node "$TMP/run.js" "$JS"
