// tests/browser/_setup.mjs — shared helpers for browser tests.
//
// Each test imports `harness` and either drives the page directly or uses
// the convenience wrappers (openSingboxPage, openEditModal, etc.). All
// errors thrown inside page.evaluate() propagate to the test runner and
// trigger `FAIL: <label>` via assert().

import puppeteer from 'puppeteer';

export const VM_HOST = process.env.VM_HOST || '192.168.100.145';
export const VM_USER = process.env.VM_USER || 'root';
export const VM_PASS = process.env.VM_PASS || 'admin';
export const LUCI_URL = `http://${VM_HOST}/cgi-bin/luci`;
export const PAGE_URL = `${LUCI_URL}/admin/services/singbox-ui`;

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

    const loginRes = await fetch(LUCI_URL, {
        method: 'POST',
        headers: { 'content-type': 'application/x-www-form-urlencoded' },
        body: `luci_username=${VM_USER}&luci_password=${VM_PASS}`,
        redirect: 'manual',
    });
    const m = (loginRes.headers.get('set-cookie') || '').match(/sysauth_http=([^;]+)/);
    if (!m) throw new Error('login failed (no sysauth_http cookie)');
    await page.setCookie({
        name: 'sysauth_http', value: m[1],
        domain: VM_HOST, path: '/cgi-bin/luci/', httpOnly: true,
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
export async function toggleAdvanced(page) {
    await page.evaluate(() => {
        const ov = document.getElementById('modal_overlay');
        const activePane = ov.querySelector('[data-tab][data-tab-active="true"]') || ov;
        const row = Array.from(activePane.querySelectorAll('.cbi-value'))
            .find(r => /show advanced fields/i.test((r.querySelector('.cbi-value-title') || {}).textContent || ''));
        if (!row) throw new Error('no "Show advanced fields" row in active tab');
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
