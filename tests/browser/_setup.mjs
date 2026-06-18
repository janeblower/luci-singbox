// tests/browser/_setup.mjs — shared helpers for browser tests.
//
// Each test imports `harness` and either drives the page directly or uses
// the convenience wrappers (openSingboxPage, openEditModal, etc.). All
// errors thrown inside page.evaluate() propagate to the test runner and
// trigger `FAIL: <label>` via assert().

import puppeteer from 'puppeteer';
import { execSync } from 'node:child_process';

// BROWSER_URL is set by tests/test_browser.sh after launching the Docker
// container, e.g. http://127.0.0.1:34567/cgi-bin/luci. LUCI_USER/PASS
// default to the container-seeded root:admin.
export const BROWSER_URL = process.env.BROWSER_URL
    || 'http://127.0.0.1:8080/cgi-bin/luci';
export const LUCI_USER = process.env.LUCI_USER || 'root';
export const LUCI_PASS = process.env.LUCI_PASS || 'admin';
export const LUCI_URL  = BROWSER_URL;
export const PAGE_URL  = `${BROWSER_URL}/admin/services/singbox-ui`;
// DOCKER_NAME is set by tests/test_browser.sh; used by containerExec() to
// run UCI/ubus/nft commands inside the test container (the container has no
// sshd, so the legacy sshpass path is unusable).
export const DOCKER_NAME = process.env.DOCKER_NAME || '';

// Execute a shell command inside the test container and return stdout. The
// container exposes BusyBox + uci/ubus/nft/logread; this is the seam tests
// use to seed UCI fixtures and probe runtime state.
//
// The command is passed via stdin so callers don't need to escape single
// quotes, embedded $vars, etc. — execSync's `input` channel handles arbitrary
// bytes safely.
//
// containerExec runs a shell command inside the test container via
// `docker exec -i ... sh`. The command is piped on stdin so we don't have
// to quote-escape anything. Synchronous — blocks the event loop for the
// duration; that's fine for short UCI seed/cleanup commands but use with
// care for anything that sleeps or waits.
export function containerExec(cmd) {
    if (!DOCKER_NAME) throw new Error('containerExec: DOCKER_NAME env var not set');
    return execSync(`docker exec -i ${DOCKER_NAME} sh`, {
        input: cmd,
        encoding: 'utf8',
        stdio: ['pipe', 'pipe', 'inherit'],
    });
}

// Open a fresh headless Chrome and an authenticated page. Returns:
//   { browser, page, errors, close() }
// errors[] accumulates pageerror events — fail any test that records any.
export async function newPage() {
    const browser = await puppeteer.launch({
        headless: 'new',
        args: ['--no-sandbox', '--disable-dev-shm-usage'],
    });
    const page = await browser.newPage();
    const errors = [];
    page.on('pageerror', err => errors.push(`[pageerror] ${err.message}`));

    // The first HTTP request to a freshly-launched uhttpd is sometimes RST'd
    // (ECONNRESET) — uhttpd accepts the socket before its request thread is
    // fully wired. Retry the login fetch 3× with 500/1000 ms backoff; any
    // non-network error (4xx/5xx, missing cookie) is surfaced on the last
    // attempt.
    let loginRes;
    for (let attempt = 0, delay = 500; attempt < 3; attempt++, delay *= 2) {
        try {
            loginRes = await fetch(LUCI_URL, {
                method: 'POST',
                headers: { 'content-type': 'application/x-www-form-urlencoded' },
                body: `luci_username=${encodeURIComponent(LUCI_USER)}&luci_password=${encodeURIComponent(LUCI_PASS)}`,
                redirect: 'manual',
            });
            break;
        } catch (e) {
            if (attempt === 2) throw e;
            await wait(delay);
        }
    }
    const m = (loginRes.headers.get('set-cookie') || '').match(/sysauth_http=([^;]+)/);
    if (!m) throw new Error('login failed (no sysauth_http cookie)');
    const cookieDomain = new URL(LUCI_URL).hostname;
    await page.setCookie({
        name: 'sysauth_http', value: m[1],
        domain: cookieDomain, path: '/cgi-bin/luci/', httpOnly: true,
    });
    return { browser, page, errors, close: () => browser.close() };
}

export async function gotoSingbox(page) {
    await page.goto(PAGE_URL, { waitUntil: 'networkidle2', timeout: 60000 });
    await wait(2500);  // let the lazy main.js bootstrap settle
}

export async function openEditModalBySid(page, kind, sid) {
    const opened = await page.evaluate((kind, sid) => {
        const row = document.querySelector(
            `#cbi-singbox-ui-${kind} tr[data-sid="${sid}"]`
        );
        if (!row) return { ok: false, reason: `no row for sid=${sid}` };
        const btn = Array.from(row.querySelectorAll('button'))
            .find(b => /edit/i.test(b.textContent));
        if (!btn) return { ok: false, reason: 'no Edit button' };
        btn.click();
        return { ok: true };
    }, kind, sid);
    if (!opened.ok) throw new Error(`openEditModal: ${opened.reason}`);
    await wait(3500);
}

// Switch the in-modal `protocol` (inbound) or `type` (outbound) dropdown.
// Required because most descriptor fields depend on the discriminator and
// won't surface until it carries the right value.
export async function setProtocolInModal(page, value, fieldLabel = 'Protocol') {
    await page.evaluate(({ value, fieldLabel }) => {
        const ov = document.getElementById('modal_overlay');
        const row = Array.from(ov.querySelectorAll('.cbi-value'))
            .find(r => (r.querySelector('.cbi-value-title') || {}).textContent === fieldLabel);
        if (!row) throw new Error(`no "${fieldLabel}" dropdown in modal`);
        const sel = row.querySelector('select');
        if (!sel) throw new Error(`"${fieldLabel}" row has no <select>`);
        sel.value = value;
        sel.dispatchEvent(new Event('change', { bubbles: true }));
    }, { value, fieldLabel });
    await wait(800);
}

// Click the <a> inside a tab <li> by data-tab name. LuCI's switchTab
// listens on the anchor, not the li.
export async function clickTab(page, tabName) {
    const r = await page.evaluate((tabName) => {
        const ov = document.getElementById('modal_overlay');
        const li = ov.querySelector(`.cbi-tabmenu > li[data-tab="${tabName}"]`);
        if (!li) return { ok: false, reason: 'no tab li' };
        if (li.style.display === 'none') return { ok: false, reason: 'tab hidden (empty)' };
        const a = li.querySelector('a');
        if (a) a.click();
        return { ok: true };
    }, tabName);
    if (!r.ok) throw new Error(`clickTab("${tabName}"): ${r.reason}`);
    await wait(400);
}

// Returns the list of visible (CSS display !== none) `<label class="cbi-value-title">`
// captions in the currently-active modal tab.
export async function visibleFieldsInActiveTab(page) {
    return page.evaluate(() => {
        const ov = document.getElementById('modal_overlay');
        const activePane = ov.querySelector('[data-tab][data-tab-active="true"]') || ov;
        return Array.from(activePane.querySelectorAll('.cbi-value'))
            .filter(v => getComputedStyle(v).display !== 'none')
            .map(v => (v.querySelector('.cbi-value-title') || {}).textContent || null)
            .filter(Boolean);
    });
}

// Currently-active tab name and the list of all tab li metadata.
export async function listTabs(page) {
    return page.evaluate(() => {
        const ov = document.getElementById('modal_overlay');
        return Array.from(ov.querySelectorAll('.cbi-tabmenu > li')).map(li => ({
            name: li.getAttribute('data-tab'),
            text: li.textContent.trim(),
            active: li.classList.contains('cbi-tab'),
            hidden: li.style.display === 'none',
        }));
    });
}

// Dismiss the open modal.
export async function dismissModal(page) {
    await page.evaluate(() => {
        const ov = document.getElementById('modal_overlay');
        const btn = ov && Array.from(ov.querySelectorAll('button'))
            .find(b => /dismiss|cancel|close/i.test(b.textContent));
        if (btn) btn.click();
    });
    await wait(500);
}

// Toggle the "Show advanced fields" virtual flag in the currently-active tab.
// Bug 4: inbound/outbound builders no longer carry this toggle — all fields are
// shown immediately. When the row is absent we no-op, so callers that toggle
// then assert an (already-visible) advanced field still pass. DNS/Route keep the
// toggle, where this still clicks it.
export async function toggleAdvanced(page) {
    await page.evaluate(() => {
        const ov = document.getElementById('modal_overlay');
        const activePane = ov.querySelector('[data-tab][data-tab-active="true"]') || ov;
        const row = Array.from(activePane.querySelectorAll('.cbi-value'))
            .find(r => /show advanced fields/i.test((r.querySelector('.cbi-value-title') || {}).textContent || ''));
        if (!row) return;  // no advanced toggle (inbound/outbound) — fields already visible
        // LuCI Flag widget: hidden input + a button-like label.
        const checkbox = row.querySelector('input[type="checkbox"]');
        if (checkbox) {
            checkbox.click();  // toggles via real click event; triggers depends
            return;
        }
        const btn = row.querySelector('button, label');
        if (btn) { btn.click(); return; }
        throw new Error('no toggleable element in Show advanced row');
    });
    await wait(500);
}

export function wait(ms) {
    return new Promise(r => setTimeout(r, ms));
}

// Tiny assertion helper. PASS messages go to stdout; FAIL exits non-zero.
export function assert(label, cond, extra) {
    if (cond) {
        console.log(`PASS: ${label}`);
        return;
    }
    console.error(`FAIL: ${label}`);
    if (extra !== undefined)
        console.error(`     ${typeof extra === 'string' ? extra : JSON.stringify(extra, null, 2)}`);
    process.exit(1);
}

// Standard test wrapper: launches a page, hands it to fn, closes cleanly,
// then asserts no pageerror leaked through.
export async function runTest(name, fn) {
    console.log(`\n=== ${name} ===`);
    const ctx = await newPage();
    try {
        await gotoSingbox(ctx.page);
        await fn(ctx);
    } finally {
        await ctx.close();
    }
    assert(`${name} — no pageerror`, ctx.errors.length === 0, ctx.errors.join('\n'));
}

// Click "Add" in the kind table and wait for the modal.
// kind: 'inbound' or 'outbound'.
// name: required — LuCI's GridSection won't enable the Add button until
//       `.cbi-section-create-name` is filled with a valid UCI section
//       name. The helper fills it, fires the input+blur events the
//       uciname validator listens on, then clicks Add.
export async function openAddModal(page, kind, name) {
    if (!name || typeof name !== 'string') {
        throw new Error(`openAddModal: name is required (kind=${kind})`);
    }
    const opened = await page.evaluate((kind, name) => {
        const tbl = document.getElementById(`cbi-singbox-ui-${kind}`);
        if (!tbl) return { ok: false, reason: `no #cbi-singbox-ui-${kind}` };

        // LuCI renders a .cbi-section-create row INSIDE the GridSection div
        // (#cbi-singbox-ui-<kind> is the .cbi-section element itself). Query
        // WITHIN that element first — when several grids share one Map (DNS:
        // dns_server + dns_rule + settings under one cbi-map), a parentElement
        // query would grab the first grid's create-name and open the WRONG
        // modal. Scoped-within is correct for every grid (verified inbound/
        // outbound/dns_server/dns_rule). Fall back to the looser lookups only
        // if the section-scoped one is somehow absent.
        const nameInp = tbl.querySelector('.cbi-section-create-name')
                       || tbl.parentElement.querySelector('.cbi-section-create-name')
                       || document.querySelector(`#cbi-singbox-ui-${kind} ~ .cbi-section-create .cbi-section-create-name`)
                       || document.querySelector('.cbi-section-create-name');
        if (!nameInp) return { ok: false, reason: 'no .cbi-section-create-name input' };

        nameInp.focus();
        nameInp.value = name;
        nameInp.dispatchEvent(new Event('input',  { bubbles: true }));
        nameInp.dispatchEvent(new Event('blur',   { bubbles: true }));
        nameInp.dispatchEvent(new Event('change', { bubbles: true }));

        const addBtn = nameInp.closest('.cbi-section-create')?.querySelector('.cbi-button-add')
                    || document.querySelector('.cbi-section-create .cbi-button-add');
        if (!addBtn) return { ok: false, reason: 'no Add button in create row' };

        // The validator may still be racing; force-enable defensively.
        addBtn.disabled = false;
        addBtn.click();
        return { ok: true };
    }, kind, name);

    if (!opened.ok) throw new Error(`openAddModal: ${opened.reason}`);
    await wait(3500);
}

// Click a TOP-LEVEL view tab (data-tab on .sb-tab-header > li). Unlike
// clickTab(), this is NOT inside #modal_overlay — it switches the whole-page
// tab wired by main.js render(). Returns true on success.
export async function clickTopTab(page, dataTab) {
    const ok = await page.evaluate((dataTab) => {
        const li = document.querySelector(`.sb-tab-header > li[data-tab="${dataTab}"]`);
        if (!li) return false;
        const a = li.querySelector('a') || li;
        a.click();
        return true;
    }, dataTab);
    await wait(800);  // let the dashboard/monitoring start()/stop() hooks settle
    return ok;
}

// Click a Route sub-tab (.sb-subtab-header > li[data-tab=routerules|rulesets|routedef]).
export async function clickSubTab(page, dataTab) {
    const ok = await page.evaluate((dataTab) => {
        const li = document.querySelector(`.sb-subtab-header > li[data-tab="${dataTab}"]`);
        if (!li) return false;
        const a = li.querySelector('a') || li;
        a.click();
        return true;
    }, dataTab);
    await wait(400);
    return ok;
}

// Node-side: parse one .mjs source string for `export const COVERS = [ ... ]`
// and return the array of string ids (or [] if none). Tolerant of single/double
// quotes and newlines. Shared by the ui-surface guard and run-all bookkeeping.
export function extractCovers(src) {
    const m = src.match(/export\s+const\s+COVERS\s*=\s*\[([\s\S]*?)\]/);
    if (!m) return [];
    return Array.from(m[1].matchAll(/['"]([^'"]+)['"]/g)).map(x => x[1]);
}

// Fill a labeled field in the currently-open modal. opts.kind selects
// the writer: 'flag' clicks a checkbox; 'select' sets value+dispatches
// change; 'text'/'number' (default) writes to input.value+input event.
//
// Caller must clickTab() into the right tab first — when two tabs use
// the same .cbi-value-title text (e.g., "Tag" on Inbound and Inbound‑TLS),
// the first DOM match wins regardless of visibility.
export async function fillField(page, label, value, opts = {}) {
    const kind = opts.kind || 'text';
    const r = await page.evaluate(({ label, value, kind }) => {
        const ov = document.getElementById('modal_overlay');
        const row = Array.from(ov.querySelectorAll('.cbi-value'))
            .find(r => (r.querySelector('.cbi-value-title') || {})
                .textContent.trim() === label);
        if (!row) return { ok: false, reason: `no row "${label}"` };
        if (kind === 'flag') {
            const cb = row.querySelector('input[type="checkbox"]');
            if (!cb) return { ok: false, reason: `"${label}" no checkbox` };
            if (Boolean(cb.checked) !== Boolean(Number(value))) cb.click();
            return { ok: true };
        }
        if (kind === 'select') {
            const sel = row.querySelector('select');
            if (!sel) return { ok: false, reason: `"${label}" no select` };
            sel.value = value;
            sel.dispatchEvent(new Event('change', { bubbles: true }));
            return { ok: true };
        }
        const inp = row.querySelector('input[type="text"], input[type="number"], input[type="password"], input:not([type])');
        if (!inp) return { ok: false, reason: `"${label}" no input` };
        inp.focus();
        inp.value = String(value);
        inp.dispatchEvent(new Event('input',  { bubbles: true }));
        inp.dispatchEvent(new Event('change', { bubbles: true }));
        return { ok: true };
    }, { label, value, kind });
    if (!r.ok) throw new Error(`fillField("${label}"): ${r.reason}`);
    await wait(300);
}

// Click modal Save (which queues UCI changes into LuCI's in-memory uci
// store), then directly call L.uci.save() to flush to disk via rpcd.
// Apply (which triggers sing-box restart) is intentionally skipped — the
// test container's /etc/init.d/sing-box is a stub, and we only want the
// UCI write so preview_config sees the new section.
//
// Empirical: clicking the action-bar "Save" button spins indefinitely
// because the modal stays open (the modal Save handler queues changes
// but LuCI's GridSection re-renders the create row without closing the
// modal_overlay). Calling L.uci.save() directly is the canonical API
// path and bypasses the button-state racing entirely.
export async function saveAndReload(page) {
    // Modal Save — positive button. Queues changes into L.uci (in-memory).
    await page.evaluate(() => {
        const ov = document.getElementById('modal_overlay');
        const btn = ov && ov.querySelector('button.cbi-button-positive');
        if (!btn) throw new Error('no modal Save (cbi-button-positive) button');
        btn.click();
    });
    await wait(2000);  // let the modal's async handler queue all field writes
    // Flush queued UCI changes via the rpcd write path. L.uci.save() pushes
    // pending in-memory changes to rpcd; L.uci.apply(0) finalises them on
    // disk WITHOUT triggering the apply-confirm dialog (timeout=0). The
    // stubbed /etc/init.d/sing-box swallows the post-write restart hook.
    const res = await page.evaluate(async () => {
        if (!window.L || !L.uci) return { err: 'no L.uci' };
        try {
            await L.uci.save();
            // apply() may reject when the rollback timer expires — that's
            // fine; the on-disk commit already happened. Swallow.
            try { await L.uci.apply(0); } catch (_) {}
            return { ok: true };
        } catch (e) { return { err: String(e) }; }
    });
    if (res?.err) throw new Error(`saveAndReload: ${res.err}`);
    // Give rpcd a moment to flush; preview_config retries 3× anyway.
    await wait(1200);
}

// Call the singbox-ui preview_config RPC from the page context, parse
// the `content` field as JSON, return the object. Retries 3× on
// transient errors (rpcd settling after UCI rewrite); backoff schedule
// 200/500/1250 ms covers ~1.95 s of rpcd reload jitter.
//
// The sysauth_http cookie is HttpOnly (newPage sets it that way to
// mirror how LuCI itself sets it). page.evaluate runs in the page
// context which cannot read HttpOnly cookies, so we extract the token
// node-side via Puppeteer's cookies API and pass it into evaluate.
export async function fetchPreviewConfig(page) {
    const cookies = await page.cookies();
    const tokenCookie = cookies.find(c => c.name === 'sysauth_http');
    if (!tokenCookie) throw new Error('no sysauth_http cookie');
    const token = tokenCookie.value;

    for (let attempt = 0, delay = 200; attempt < 3; attempt++, delay *= 2.5) {
        try {
            const result = await page.evaluate(async (token) => {
                const r = await fetch('/cgi-bin/luci/admin/ubus', {
                    method: 'POST',
                    headers: { 'content-type': 'application/json' },
                    body: JSON.stringify({
                        jsonrpc: '2.0', id: 1, method: 'call',
                        params: [token, 'singbox-ui', 'preview_config', {}],
                    }),
                });
                const j = await r.json();
                if (j.error) throw new Error('ubus error: ' + JSON.stringify(j.error));
                const payload = j.result?.[1];
                // preview_config emits { status: "ok", content: "<json>" } on
                // success; some older paths used "success" — accept both.
                const okStatus = payload && (payload.status === 'ok' || payload.status === 'success');
                if (!okStatus || !payload.content)
                    throw new Error('bad preview_config payload: '
                                    + JSON.stringify(payload).slice(0, 200));
                return payload.content;
            }, token);
            return JSON.parse(result);
        } catch (e) {
            if (attempt === 2) throw e;
            await wait(delay);
        }
    }
}
