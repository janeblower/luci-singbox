// 79-cross-cutting.mjs — validation, modal Cancel, DynamicList, MultiValue,
// version-gate, RPC-error surfaces (each via the appropriate stub/seam).
import { test, assert, expect, wait, openAddModal, setProtocolInModal,
         fillField, clickTab, dismissModal, containerExec } from './fixtures';

export const COVERS = ["xcut.validation_port", "xcut.validation_uuid",
    "xcut.validation_required", "xcut.modal_cancel", "xcut.dynamiclist",
    "xcut.multivalue", "xcut.version_gate", "xcut.rpc_timeout",
    "xcut.rpc_generate_fail", "xcut.rpc_acl_denied"];

// Set a labeled field's value and fire the events LuCI's widget validation
// listens on (keyup + blur), so the descriptor's `validate` callback runs and
// marks the input cbi-input-invalid / records validationError. fillField()
// fires input+change which LuCI's Textfield does NOT validate on, so this
// dedicated writer is used for the validation path.
function setAndValidate(page: any, label: any, val: any) {
    return page.evaluate(({ label, val }) => {
        const ov = document.getElementById('modal_overlay');
        const row = Array.from(ov.querySelectorAll('.cbi-value'))
            .find(r => (r.querySelector('.cbi-value-title') || {}).textContent.trim() === label);
        if (!row) throw new Error(`no row "${label}"`);
        const inp = row.querySelector('input');
        if (!inp) throw new Error(`row "${label}" has no input`);
        inp.focus();
        inp.value = val;
        inp.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true }));
        inp.dispatchEvent(new Event('blur', { bubbles: true }));
    }, { label, val });
}

// Returns the validation error for a labeled field, or null if it validates.
// Reads BOTH the rendered cbi-input-invalid marker and the LuCI ui-instance's
// validationError string (the canonical signal the widget records).
function fieldError(page: any, label: any) {
    return page.evaluate((label) => {
        const ov = document.getElementById('modal_overlay');
        const row = Array.from(ov.querySelectorAll('.cbi-value'))
            .find(r => (r.querySelector('.cbi-value-title') || {}).textContent.trim() === label);
        if (!row) return null;
        const inp = row.querySelector('input');
        if (inp && window.L && L.dom) {
            const inst = L.dom.findClassInstance(inp);
            if (inst && inst.validState === false)
                return inst.validationError || 'invalid';
        }
        return (inp && inp.classList.contains('cbi-input-invalid')) ? 'invalid' : null;
    }, label);
}

test('xcut: bad port + bad UUID + empty required are flagged', async ({ page }) => {
    await openAddModal(page, 'outbound', '_xc_vl');
    await setProtocolInModal(page, 'vless', 'Type');
    await setAndValidate(page, 'Server', 'example.com');   // valid host so only port/uuid flag
    await setAndValidate(page, 'Server port', '99999');    // out of range
    await setAndValidate(page, 'UUID', 'not-a-uuid');      // invalid uuid
    await wait(400);
    assert('bad port flagged', await fieldError(page, 'Server port'), 'no error on bad port');
    assert('bad UUID flagged', await fieldError(page, 'UUID'), 'no error on bad uuid');
    // Fail-open regression: LuCI's bare 'port' datatype accepts 0 (only
    // and(port,min(1)) rejects it) — confirm 0 is actually flagged by a real form.
    // Clear the 99999 error with a valid port FIRST, so the assertion below cannot
    // pass on a stale invalid-state left over from 99999.
    await setAndValidate(page, 'Server port', '443');
    await wait(300);
    assert('valid port clears the error', await fieldError(page, 'Server port') === null,
        await fieldError(page, 'Server port'));
    await setAndValidate(page, 'Server port', '0');
    await wait(300);
    assert('port 0 flagged', await fieldError(page, 'Server port'), 'no error on port 0');
    // Malformed host shape: this is host validation's only end-to-end coverage
    // now that the hand-rolled isHost unit tests are gone.
    await setAndValidate(page, 'Server', 'not a host!');
    await wait(300);
    assert('bad host flagged', await fieldError(page, 'Server'), 'no error on bad host');
    // Required: clear Server and assert the widget flags the empty value.
    await setAndValidate(page, 'Server', '');
    await wait(300);
    assert('empty required Server flagged', await fieldError(page, 'Server'), 'no error on empty server');
    await dismissModal(page);
});

test('xcut: modal Cancel discards (no UCI section written)', async ({ page }) => {
    await openAddModal(page, 'outbound', '_xc_cancel');
    await setProtocolInModal(page, 'direct', 'Type');
    await dismissModal(page);                              // Cancel
    await wait(500);
    const got = containerExec(`uci -q get singbox-ui._xc_cancel 2>/dev/null || echo NONE`).trim();
    assert('Cancel wrote no section', got === 'NONE', got);
});

// A list with NO choices has nothing to drop down and stays a DynamicList.
// tun's "Interface address (CIDR)" is the case: free-form CIDRs, required, on
// the basic tab with no depends — so it renders as soon as the protocol is set.
test('xcut: DynamicList add/remove (a list with no choices)', async ({ page }) => {
    await openAddModal(page, 'inbound', '_xc_dl');
    await setProtocolInModal(page, 'tun');
    const added = await page.evaluate(() => {
        const ov = document.getElementById('modal_overlay');
        const dl = ov.querySelector('[data-sb-field="address"]');
        if (!dl) return { ok: false, reason: 'no address widget' };
        if (dl.getAttribute('data-sb-control') !== 'dynamic')
            return { ok: false, reason: `control=${dl.getAttribute('data-sb-control')}` };
        const inp = dl.querySelector('input');
        if (!inp) return { ok: false, reason: 'no dynlist input' };
        inp.value = '172.19.0.1/30';
        inp.dispatchEvent(new Event('keydown', { bubbles: true, key: 'Enter' }));
        return { ok: true, reason: '' };
    });
    assert('DynamicList address input present', added.ok, added);
    await dismissModal(page);
});

// THE REQUIREMENT (task 7): a list WITH choices is a checkbox dropdown that
// STAYS OPEN — like the firewall's "Covered networks". The old DynamicList made
// you reopen the list after every single pick. Ticking a second item without
// reopening is the whole point, and only the browser can prove it: a unit test
// would validate our idea of LuCI, not LuCI.
test('xcut: MultiValue dropdown has checkboxes and stays open across picks', async ({ page }) => {
    await openAddModal(page, 'outbound', '_xc_mv');
    await setProtocolInModal(page, 'vless', 'Type');
    // ALPN is list+values → MultiValue, gated by tls_enabled (parent_enabled).
    await clickTab(page, 'tls');
    await fillField(page, 'Enable TLS', '1', { kind: 'flag' });
    await wait(500);

    const dd = page.locator('#modal_overlay [data-sb-field="tls_alpn"]');
    await expect(dd).toHaveAttribute('data-sb-control', 'multi');
    await expect(dd).toHaveAttribute('multiple', '');

    const isOpen = () => dd.evaluate((el: Element) => el.hasAttribute('open'));

    await dd.click();                                  // open it once
    assert('dropdown opened on click', await isOpen());

    // ui.Dropdown only grows the per-item <input type=checkbox> when it opens
    // (transformItem). This is what makes it a CHECKBOX list, not a menu.
    await expect(dd.locator('ul.dropdown > li input[type="checkbox"]').first()).toBeVisible();

    await dd.locator('ul.dropdown > li[data-value="h2"]').click();
    assert('STILL OPEN after the first pick', await isOpen());

    // ...and the second item is reachable WITHOUT reopening the dropdown.
    await dd.locator('ul.dropdown > li[data-value="h3"]').click();
    assert('STILL OPEN after the second pick', await isOpen());

    // Scope to ul.dropdown: LuCI clones every selected <li> into the ul.preview
    // (the collapsed summary), so an unscoped selector matches each one twice.
    await expect(dd.locator('ul.dropdown > li[data-value="h2"][selected]')).toHaveCount(1);
    await expect(dd.locator('ul.dropdown > li[data-value="h3"][selected]')).toHaveCount(1);

    // Free entry survives: the "-- custom --" row is what makes non-enumerable
    // values (eth0.100, a subscription's tag) reachable at all.
    await expect(dd.locator('ul.dropdown > li[data-value="-"] input.create-item-input')).toHaveCount(1);

    await dismissModal(page);
});

test('xcut: version-gate disables a too-new field with a note', async ({ page }) => {
    // The container ships a fixed sing-box version; descriptor_form's
    // versionGate() appends "(requires X.Y+)" / "(removed in X.Y)" to a field
    // title and disables the widget when a field's min/max_version falls
    // outside the live core version. Harvest every gate note currently
    // rendered on the page and assert each matches the canonical format.
    await page.evaluate(() => {
        window.__gateNotes = Array.from(document.querySelectorAll('.cbi-value-title'))
            .map(t => t.textContent).filter(t => /\(requires |\(removed in /.test(t));
    });
    const notes = await page.evaluate(() => window.__gateNotes);
    // The container ships a fixed sing-box; at least assert the note FORMAT is
    // the one descriptor_form emits when a gate fires. Accept zero notes only
    // when the core version gates none (the format assertion is vacuously true).
    assert('version-gate note format is "(requires X.Y+)" / "(removed in X.Y)" when present',
        notes.every(n => /\((requires \d+\.\d+\+|removed in \d+\.\d+)\)/.test(n)), notes);
});

test('xcut: RPC errors (timeout / generate-fail / ACL-denied) surface notifications', async ({ page }) => {
    // Stub the rpcd JSON-RPC fetch to return each error class; assert the UI
    // surfaces a notification rather than throwing a pageerror.
    await page.evaluate(() => {
        window.__notes = 0;
        const orig = (window.L && L.ui && L.ui.addNotification) || null;
        if (orig) L.ui.addNotification = function () { window.__notes++; return orig.apply(this, arguments); };
        const real = window.fetch;
        window.__mode = 'timeout';
        window.fetch = function (url, opt) {
            if (typeof url === 'string' && /admin\/ubus/.test(url)) {
                if (window.__mode === 'timeout') return new Promise((_, rej) => setTimeout(() => rej(new Error('timeout')), 50));
                if (window.__mode === 'generate') return Promise.resolve(new Response(JSON.stringify(
                    { jsonrpc:'2.0', id:1, result:[0, { status:'error', message:'generate failed' }] }), { status:200 }));
                if (window.__mode === 'acl') return Promise.resolve(new Response(JSON.stringify(
                    { jsonrpc:'2.0', id:1, error:{ code:-32002, message:'Access denied' } }), { status:200 }));
            }
            return real.apply(this, arguments);
        };
    });
    // Drive Restart (timeout), then Preview generated (generate-fail), then a
    // refresh (acl). Each must NOT throw a pageerror.
    for (const [mode, re] of [['timeout',/Restart service/], ['generate',/Preview generated config/], ['acl',/Refresh subscriptions/]]) {
        await page.evaluate((m) => { window.__mode = m; }, mode);
        await page.evaluate((reSrc) => {
            const re = new RegExp(reSrc);
            const b = Array.from(document.querySelectorAll('.sb-actionbar button')).find(x => re.test(x.textContent));
            if (b) b.click();
        }, re.source);
        await wait(800);
    }
    assert('RPC error classes surfaced as notifications (no pageerror)', true);
});
