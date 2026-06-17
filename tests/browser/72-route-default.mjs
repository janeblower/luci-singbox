// 72-route-default.mjs — Route › Default sub-tab. route_default is a
// NamedSection rendered INLINE on the page (no modal_overlay), so we set its
// Action/Outbound selects directly on the document and flush via L.uci.save()
// — mirroring what saveAndReload() does internally for modals.
//
// route.uc maps route_default action=route + outbound -> config.route.final;
// action=reject -> a trailing { action: "reject" } rule (final stays null).
import { runTest, assert, wait, clickTopTab, clickSubTab,
         fetchPreviewConfig, containerExec } from './_setup.mjs';

export const COVERS = ["subtab.routedef", "route.default.action", "route.default.outbound"];

// Page-level select setter: like setSelectByLabel but scoped to `document`
// (route_default renders inline, not inside #modal_overlay). Matches the
// .cbi-value row whose title text equals `label`, sets the <select> value and
// dispatches change so LuCI's depends/visibility logic runs.
async function setPageSelectByLabel(page, label, value) {
    const r = await page.evaluate(({ label, value }) => {
        const rows = Array.from(document.querySelectorAll('.cbi-value'))
            .filter(v => !v.closest('#modal_overlay'));
        const row = rows.find(v =>
            ((v.querySelector('.cbi-value-title') || {}).textContent || '').trim() === label);
        if (!row) return { ok: false, reason: `no row "${label}"` };
        const sel = row.querySelector('select');
        if (!sel) return { ok: false, reason: `"${label}" has no <select>` };
        sel.value = value;
        sel.dispatchEvent(new Event('change', { bubbles: true }));
        return { ok: true, got: sel.value };
    }, { label, value });
    if (!r.ok) throw new Error(`setPageSelectByLabel("${label}"): ${r.reason}`);
    await wait(400);
    return r.got;
}

// Persist inline-form edits. The page Save button (.cbi-page-actions
// .cbi-button-save) runs the view's handleSave, which calls m.parse() on every
// Map (staging the DOM widget values into uci's change-set) and then uci.save().
// A raw L.uci.save() alone would NOT capture the select edits because the form
// widgets only commit on parse(). After clicking Save we apply(0) to finalise on
// disk without the rollback-confirm dialog; a rollback-timer reject is benign.
async function savePageUci(page) {
    const clicked = await page.evaluate(() => {
        const btn = document.querySelector('.cbi-page-actions .cbi-button-save');
        if (!btn) return { ok: false, reason: 'no page Save button' };
        btn.click();
        return { ok: true };
    });
    if (!clicked.ok) throw new Error(`savePageUci: ${clicked.reason}`);
    await wait(2000);  // let handleSave's parse()+uci.save() resolve
    const res = await page.evaluate(async () => {
        if (!window.L || !L.uci) return { err: 'no L.uci' };
        try {
            // handleSave already flushed via uci.save(); finalise on disk.
            try { await L.uci.apply(0); } catch (_) {}
            return { ok: true };
        } catch (e) { return { err: String(e) }; }
    });
    if (res?.err) throw new Error(`savePageUci: ${res.err}`);
    await wait(1200);
}

await runTest('route: default action/outbound emits route.final', async ({ page }) => {
    await clickTopTab(page, 'route');
    await clickSubTab(page, 'routedef');
    await wait(400);

    // Action = route, Outbound = direct_wan (a defined seed outbound, so it is
    // NOT dropped by route.uc's ob_ok() check).
    const a = await setPageSelectByLabel(page, 'Action', 'route');
    assert('Default Action set to route', a === 'route', a);
    // The Outbound select depends('action','route'); after the change above it
    // is visible and populated from outbound sections.
    const o = await setPageSelectByLabel(page, 'Outbound', 'direct_wan');
    assert('Default Outbound set to direct_wan', o === 'direct_wan', o);

    await savePageUci(page);

    const json = await fetchPreviewConfig(page);
    assert('route.final emitted from route_default',
        json.route && json.route.final === 'direct_wan',
        JSON.stringify(json.route));

    // Cleanup: restore the baseline route_default values so re-runs start clean.
    // test_browser.sh also snapshots/restores /etc/config/singbox-ui per file as
    // belt-and-braces, so this is defensive.
    containerExec(
        'uci set singbox-ui.route_default.action=route; ' +
        'uci set singbox-ui.route_default.outbound=direct; ' +
        'uci commit singbox-ui');
});
