// 75-dashboard.mjs — Dashboard buttons (sort/test/update/choose-node) with the
// clash-api RPCs stubbed in the page context.
//
// The Dashboard tab polls the singbox-ui rpcd handler (clash_get /proxies|
// /version|/connections, clash_mutate, clash_delay, sub_status) which proxies
// to a live clash-api that does NOT exist in the browser-container. To drive
// the buttons deterministically we intercept the JSON-RPC transport BEFORE the
// tab starts polling and answer from in-page fixtures.
//
// Transport seam: LuCI's `rpc` module posts to admin/ubus via the `request`
// module, which uses XMLHttpRequest (NOT window.fetch) and BATCHES calls (the
// request body is a single JSON-RPC object OR an array of them). So we patch
// XMLHttpRequest, not fetch — a window.fetch stub catches nothing here. Each
// {method:'call', params:[sid, 'singbox-ui', <m>, <args>]} message is answered
// with {jsonrpc:'2.0', id, result:[0, payload]} (LuCI's rpc expects
// result:[code, payload]; code 0 = OK). dashboard.js reads res.status/res.body.
//
// Buttons exercised (verified against tabs/dashboard.js):
//   .sb-sort-btn            -> setSortByLatency()           (mountChrome)
//   .sb-dashboard-test      -> testGroup() -> clash_delay   (renderGroups)
//   .sb-dashboard-node-sel  -> chooseNode() -> clash_mutate (nodeRow, selector)
//   .sb-dashboard-sub-update-> updateSub()  -> refresh      (renderSubscriptions)
import { runTest, assert, wait, clickTopTab } from './_setup.mjs';

export const COVERS = ["tab.dashboard",
    "dashboard.sort", "dashboard.test", "dashboard.update_sub", "dashboard.choose_node"];

await runTest('dashboard: sort/test/update/choose-node buttons fire RPCs', async ({ page }) => {
    // Install the XHR stub BEFORE clicking the tab (which calls start()/poll()).
    await page.evaluate(() => {
        const proxies = { proxies: {
            grp1: { type: 'Selector', all: ['n1','n2'], now: 'n1' },
            n1: { type: 'vless', history: [{ delay: 120 }] },
            n2: { type: 'vless', history: [{ delay: 0 }] }
        }};
        // sub_status fixture so the dedicated Subscriptions section (with its
        // Update button) renders deterministically.
        const subs = { subscriptions: [ { name: 'sub1', node_count: 2, last_update: 1000 } ], now: 2000 };
        window.__rpc = { mutate: [], delay: [], refresh: [] };
        const R = (id, payload) => ({ jsonrpc: '2.0', id, result: [0, payload] });
        function reply(msg) {
            const p = msg.params || [];
            const method = p[2], args = p[3] || {};
            if (method === 'clash_get') {
                const path = args.path || '';
                if (/proxies/.test(path)) return R(msg.id, { status:'ok', body: JSON.stringify(proxies) });
                if (/version/.test(path))  return R(msg.id, { status:'ok', body: '{"version":"1.12.0"}' });
                return R(msg.id, { status:'ok', body: '{"connections":[],"downloadTotal":0,"uploadTotal":0}' });
            }
            if (method === 'sub_status')   return R(msg.id, subs);
            if (method === 'clash_mutate') { window.__rpc.mutate.push(args); return R(msg.id, { status:'ok', body:'{}' }); }
            if (method === 'clash_delay')  { window.__rpc.delay.push(args); return R(msg.id, { status:'ok', body:'{"delay":99}' }); }
            if (method === 'refresh')      { window.__rpc.refresh.push(args); return R(msg.id, { status:'ok' }); }
            return R(msg.id, null);
        }
        const RealXHR = window.XMLHttpRequest;
        window.XMLHttpRequest = function StubXHR() {
            const xhr = new RealXHR();
            let url = '';
            const open = xhr.open.bind(xhr);
            xhr.open = function (m, u) { url = String(u); return open.apply(xhr, arguments); };
            const send = xhr.send.bind(xhr);
            xhr.send = function (bodyStr) {
                if (/admin\/ubus/.test(url) && bodyStr) {
                    let req; try { req = JSON.parse(bodyStr); } catch (e) { req = null; }
                    if (req) {
                        const out = Array.isArray(req) ? req.map(reply) : reply(req);
                        Object.defineProperty(xhr, 'readyState',    { configurable:true, get:()=>4 });
                        Object.defineProperty(xhr, 'status',        { configurable:true, get:()=>200 });
                        Object.defineProperty(xhr, 'responseText',  { configurable:true, get:()=>JSON.stringify(out) });
                        Object.defineProperty(xhr, 'response',      { configurable:true, get:()=>JSON.stringify(out) });
                        setTimeout(() => { if (xhr.onreadystatechange) xhr.onreadystatechange(); }, 0);
                        return;
                    }
                }
                return send.apply(xhr, arguments);
            };
            return xhr;
        };
    });
    await clickTopTab(page, 'dashboard');
    await wait(2500);   // let one poll cycle render the group + subscriptions

    // The group should have rendered from the /proxies fixture; if not, the
    // selectors below have nothing to act on — surface that explicitly.
    const grpRendered = await page.evaluate(() => !!document.querySelector('.sb-dashboard-group'));
    assert('proxy group rendered from /proxies fixture', grpRendered);

    // Sort button
    const sorted = await page.evaluate(() => {
        const b = document.querySelector('.sb-sort-btn'); if (!b) return false; b.click(); return true;
    });
    assert('Sort-by-latency button present + clicked', sorted);

    // Update (subscription) button → refresh RPC recorded with the sub name
    await page.evaluate(() => {
        const b = document.querySelector('.sb-dashboard-sub-update'); if (b) b.click();
    });
    await wait(800);
    const refreshed = await page.evaluate(
        () => window.__rpc.refresh.map(r => r && r.name));
    assert('Update button issued a refresh RPC carrying sub name',
        refreshed.length >= 1 && refreshed.indexOf('sub1') >= 0, refreshed);

    // Test button → clash_delay RPCs recorded
    await page.evaluate(() => { const b = document.querySelector('.sb-dashboard-test'); if (b) b.click(); });
    await wait(1200);
    const delays = await page.evaluate(() => window.__rpc.delay.length);
    assert('Test button issued clash_delay probes', delays >= 1, delays);

    // Choose node (selector) → clash_mutate PUT recorded
    await page.evaluate(() => { const n = document.querySelector('.sb-dashboard-node-sel'); if (n) n.click(); });
    await wait(800);
    const muts = await page.evaluate(() => window.__rpc.mutate.length);
    assert('choose-node issued clash_mutate', muts >= 1, muts);
});
