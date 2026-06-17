// 76-monitoring.mjs — Monitoring tab buttons/filters with the clash-api
// /connections feed stubbed in the page context.
//
// Same transport seam as 75-dashboard.mjs: LuCI's rpc posts to admin/ubus via
// XMLHttpRequest (NOT window.fetch) and batches messages, so we patch XHR and
// answer each {method:'call', params:[sid, obj, m, args]} with result:[0,
// payload]. start() also calls callDhcpLeases (luci-rpc getDHCPLeases), which
// we answer with an empty lease set so it doesn't reject. The connection feed
// carries two rows on two distinct devices so the search + device filters have
// something to narrow.
//
// Elements exercised (verified against tabs/monitoring.js):
//   btnActive / btnClosed   -> text "Active N" / "Closed N" (updateRows)
//   input[type=search]      -> debouncedSearch (200ms) -> state.search
//   select (device)         -> state.filterDevice (options incl. "All devices")
//   per-row Close button     -> closeConn() -> clash_mutate DELETE /connections/<id>
//   Close all button         -> closeAll()  -> clash_mutate DELETE /connections
import { runTest, assert, wait, clickTopTab } from './_setup.mjs';

export const COVERS = ["tab.monitoring",
    "monitoring.tab_active", "monitoring.tab_closed", "monitoring.search",
    "monitoring.device", "monitoring.close_conn", "monitoring.close_all"];

await runTest('monitoring: active/closed/search/device/close/close-all drive clash RPCs', async ({ page }) => {
    await page.evaluate(() => {
        const conns = { connections: [
            { id: 'c1', download: 100, upload: 10, chains: ['proxy'],
              metadata: { host: 'alpha.example', destinationPort: '443',
                          sourceIP: '10.0.0.5', network: 'tcp' } },
            { id: 'c2', download: 200, upload: 20, chains: ['direct'],
              metadata: { host: 'beta.example', destinationPort: '80',
                          sourceIP: '10.0.0.6', network: 'tcp' } }
        ], downloadTotal: 300, uploadTotal: 30 };
        window.__rpc = { mutate: [] };
        const R = (id, payload) => ({ jsonrpc: '2.0', id, result: [0, payload] });
        function reply(msg) {
            const p = msg.params || [];
            const obj = p[1], method = p[2], args = p[3] || {};
            if (method === 'clash_get')    return R(msg.id, { status:'ok', body: JSON.stringify(conns) });
            if (method === 'clash_mutate') { window.__rpc.mutate.push(args); return R(msg.id, { status:'ok', body:'{}' }); }
            // luci-rpc getDHCPLeases (declared with expect {'':{}}): answer empty.
            if (method === 'getDHCPLeases' || obj === 'luci-rpc') return R(msg.id, { dhcp_leases: [] });
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
    await clickTopTab(page, 'monitoring');
    await wait(2500);   // let one poll cycle ingest + repaint the table

    // Helper: click a toolbar button whose text matches a regex.
    const clickBtnByText = (re) => page.evaluate((reStr) => {
        const rx = new RegExp(reStr);
        const b = Array.from(document.querySelectorAll('.sb-monitoring button'))
            .find(x => rx.test((x.textContent || '').trim()));
        if (!b) return false; b.click(); return true;
    }, re.source);

    // Count active-tab data rows (exclude the "No connections" placeholder row,
    // which has a single <td colspan=6>; data rows have 6 <td> children).
    const rowCount = () => page.evaluate(() =>
        Array.from(document.querySelectorAll('.sb-monitoring tbody tr'))
            .filter(tr => tr.querySelectorAll('td').length === 6).length);

    const initial = await rowCount();
    assert('two active connections rendered', initial === 2, initial);

    // Active / Closed tab buttons present (text "Active N" / "Closed N").
    const active = await clickBtnByText(/^Active/);
    assert('Active tab button present + clicked', active);
    const closed = await clickBtnByText(/^Closed/);
    assert('Closed tab button present + clicked', closed);
    // Back to active for the filter/close assertions.
    await clickBtnByText(/^Active/);
    await wait(300);

    // Search filter: type a host substring matching only one row.
    await page.evaluate(() => {
        const s = document.querySelector('.sb-monitoring input[type=search]');
        if (!s) throw new Error('no search input');
        s.focus(); s.value = 'alpha';
        s.dispatchEvent(new Event('keyup', { bubbles: true }));
    });
    await wait(500);   // debouncedSearch is 200ms
    const afterSearch = await rowCount();
    assert('search filter shrinks the row count', afterSearch === 1, afterSearch);

    // Clear the search so the device filter sees both rows.
    await page.evaluate(() => {
        const s = document.querySelector('.sb-monitoring input[type=search]');
        s.value = ''; s.dispatchEvent(new Event('keyup', { bubbles: true }));
    });
    await wait(500);

    // Device filter: the <select> carries an option per sourceIP. Pick 10.0.0.6.
    const devSwitched = await page.evaluate(() => {
        const sel = document.querySelector('.sb-monitoring select');
        if (!sel) return false;
        const opt = Array.from(sel.options).find(o => o.value === '10.0.0.6');
        if (!opt) return false;
        sel.value = '10.0.0.6';
        sel.dispatchEvent(new Event('change', { bubbles: true }));
        return true;
    });
    assert('device <select> carries the connection device option', devSwitched);
    await wait(400);
    const afterDevice = await rowCount();
    assert('device filter narrows to one row', afterDevice === 1, afterDevice);

    // Reset device filter to "all" before closing.
    await page.evaluate(() => {
        const sel = document.querySelector('.sb-monitoring select');
        sel.value = 'all'; sel.dispatchEvent(new Event('change', { bubbles: true }));
    });
    await wait(300);

    // Per-row Close → clash_mutate DELETE /connections/<id>.
    await page.evaluate(() => {
        const b = Array.from(document.querySelectorAll('.sb-monitoring tbody button'))
            .find(x => /close/i.test((x.textContent || '').trim()));
        if (b) b.click();
    });
    await wait(800);
    const closeOne = await page.evaluate(() =>
        window.__rpc.mutate.some(r => r && r.method === 'DELETE' && /^\/connections\/c[12]$/.test(r.path)));
    assert('per-row Close issued clash_mutate DELETE /connections/<id>', closeOne,
        await page.evaluate(() => window.__rpc.mutate));

    // Close all → clash_mutate DELETE /connections (no id).
    await page.evaluate(() => {
        const b = Array.from(document.querySelectorAll('.sb-monitoring button'))
            .find(x => /^Close all$/.test((x.textContent || '').trim()));
        if (b) b.click();
    });
    await wait(800);
    const closeAll = await page.evaluate(() =>
        window.__rpc.mutate.some(r => r && r.method === 'DELETE' && r.path === '/connections'));
    assert('Close all issued clash_mutate DELETE /connections', closeAll,
        await page.evaluate(() => window.__rpc.mutate));
});
