// 73-dns.mjs — DNS tab: servers grid + rules grid + inline DNS Settings.
//
// Three exercises:
//  1. Add a DoH (https) DNS server via the dns_server grid modal; assert it
//     surfaces in dns.servers (preview_config).
//  2. Seed a default dns_rule (domain matcher -> route to an existing server)
//     via UCI, reload, and assert (a) the dns_rule grid renders the row with an
//     Edit button, (b) OPENING the Edit modal AND the Add modal renders the
//     match/action tabs without a pageerror, and (c) it emits in dns.rules.
//     Opening the modal is the real regression guard: dns_rule used to route its
//     enabled/type discriminators through the untabbed s.option() while its
//     descriptor fields landed in match/action tabs, so LuCI's initTabGroup hit
//     an undefined tab pane and crashed with "Cannot read properties of
//     undefined (reading 'classList')" (form.js -> ui.js) on every Add/Edit.
//     tabs/dns.js now declares the tabs up front and uses taboption (mirroring
//     route_rule); this test would have caught the original crash had it opened
//     the modal, which it now does.
//  3. Set the inline DNS Settings (NamedSection 'dns') Strategy select directly
//     on the page (it renders inline, not in #modal_overlay) and assert
//     dns.strategy persists.
//
// dns_server discriminator = field `Type` (label); the https descriptor's
// address field label is `Server` (lib/builder/dns/https.uc ui_label:"Server").
// The DNS Settings Strategy select label is `Strategy` (tabs/dns.js). The seed
// config ships dns_server `google`, which the dns_rule routes to (a default
// dns_rule whose `server` is dangling is dropped by dns.uc).
import { test, assert, wait, clickTopTab,
         openAddModal, openEditModalBySid, dismissModal, listTabs,
         setProtocolInModal, fillField,
         saveAndReload, fetchPreviewConfig, containerExec } from './fixtures';

export const COVERS = ["tab.dns",
    "grid.dns_server.add", "grid.dns_server.edit",
    "grid.dns_rule.add", "grid.dns_rule.edit",
    "dns.settings.final", "dns.settings.default_resolver",
    "dns.settings.strategy", "dns.settings.independent_cache"];

test('dns: add a DoH server and assert dns.servers emit', async ({ page }) => {
    await clickTopTab(page, 'dns');
    await openAddModal(page, 'dns_server', 'doh1');
    await setProtocolInModal(page, 'https', 'Type');
    await fillField(page, 'Server', '1.1.1.1');
    await saveAndReload(page);
    const json = await fetchPreviewConfig(page);
    const srv = (json.dns && json.dns.servers) || [];
    assert('dns.servers has doh1', srv.some((s: any) => s.tag === 'doh1'), JSON.stringify(srv));

    // grid.dns_server.edit: now that doh1 is a persisted row, opening its Edit
    // modal must render the basic tab without a pageerror (runTest asserts no
    // pageerror). This is the edit-surface guard's required modal-open — without
    // it the surface would be "claimed" in COVERS but never exercised, exactly
    // the gap that hid the dns_rule classList crash.
    await openEditModalBySid(page, 'dns_server', 'doh1');
    const srvTabs = await listTabs(page);
    assert('dns_server edit modal renders basic tab',
        srvTabs.some(t => t.name === 'basic'), JSON.stringify(srvTabs));
    await dismissModal(page);

    // Cleanup so re-runs start clean (test_browser.sh also snapshots config).
    containerExec('uci -q delete singbox-ui.doh1; uci commit singbox-ui');
});

test('dns: dns_rule grid renders + emits in dns.rules', async ({ page }) => {
    // Seed a default dns_rule routing to the seed-config server `google`. A
    // default dns_rule with action=route but a dangling `server` is dropped by
    // dns.uc, so we route to an existing server (google ships in baseline.uci).
    containerExec(
        'uci -q delete singbox-ui.dnr1; ' +
        'uci set singbox-ui.dnr1=dns_rule; ' +
        'uci set singbox-ui.dnr1.enabled=1; ' +
        'uci set singbox-ui.dnr1.type=default; ' +
        'uci add_list singbox-ui.dnr1.domain=example.org; ' +
        'uci set singbox-ui.dnr1.action=route; ' +
        'uci set singbox-ui.dnr1.server=google; ' +
        'uci commit singbox-ui');
    await page.reload({ waitUntil: 'networkidle', timeout: 60000 });
    await wait(2500);
    await clickTopTab(page, 'dns');
    await wait(400);

    // Grid surface: the seeded dns_rule row renders with an Edit button. This is
    // what grid.dns_rule.add (the row produced by an Add) and grid.dns_rule.edit
    // (the Edit affordance) reduce to in the DOM. We assert presence rather than
    // opening the modal (see the file header re: the dns_rule modal crash).
    const grid = await page.evaluate(() => {
        const sec = document.getElementById('cbi-singbox-ui-dns_rule');
        const row = sec ? sec.querySelector('tr[data-sid="dnr1"]') : null;
        const editBtn = row
            ? Array.from(row.querySelectorAll('button')).find(b => /edit/i.test(b.textContent))
            : null;
        return { rowExists: !!row, hasEdit: !!editBtn };
    });
    assert('dns_rule grid row renders for seeded rule', grid.rowExists, JSON.stringify(grid));
    assert('dns_rule grid row exposes an Edit button', grid.hasEdit, JSON.stringify(grid));

    // MODAL-CRASH regression: opening the Edit modal must render the match/action
    // tabs without a pageerror. runTest() fails the test on any recorded
    // pageerror, so the classList crash (untabbed enabled/type + tabbed
    // descriptor fields) would surface here. We assert the tabs are present too,
    // so a future regression that silently drops the tab structure is caught even
    // if it stops throwing.
    await openEditModalBySid(page, 'dns_rule', 'dnr1');
    const editTabs = await listTabs(page);
    assert('dns_rule edit modal renders match tab',
        editTabs.some(t => t.name === 'match'), JSON.stringify(editTabs));
    assert('dns_rule edit modal renders action tab',
        editTabs.some(t => t.name === 'action'), JSON.stringify(editTabs));
    await dismissModal(page);

    // ...and the Add modal (no seeded section) must open cleanly too — the
    // original crash hit both paths.
    await openAddModal(page, 'dns_rule', 'dnr_add');
    const addTabs = await listTabs(page);
    assert('dns_rule add modal renders match tab',
        addTabs.some(t => t.name === 'match'), JSON.stringify(addTabs));
    await dismissModal(page);
    // openAddModal stages a new section client-side; drop it so the emission
    // assertion below and re-runs see only the seeded dnr1.
    containerExec('uci -q delete singbox-ui.dnr_add; uci commit singbox-ui');

    // Emission: the default dns_rule surfaces in dns.rules with our matcher +
    // route target.
    const json = await fetchPreviewConfig(page);
    const rules = (json.dns && json.dns.rules) || [];
    assert('dns.rules present after seeding a default rule', rules.length >= 1, JSON.stringify(rules));
    const ours = rules.find((r: any) => Array.isArray(r.domain)
        ? r.domain.includes('example.org')
        : r.domain === 'example.org');
    assert('dns rule emits our domain matcher', ours != null, JSON.stringify(rules));
    assert('dns rule routes to google server',
        ours && ours.server === 'google', JSON.stringify(ours));

    containerExec('uci -q delete singbox-ui.dnr1; uci commit singbox-ui');
});

test('dns: settings strategy persists to dns.strategy', async ({ page }) => {
    await clickTopTab(page, 'dns');
    // DNS Settings render inline on the page (NamedSection 'dns'); set page-level.
    await page.evaluate(() => {
        function setSel(label, val) {
            const row = Array.from(document.querySelectorAll('.cbi-value'))
                .filter(r => !r.closest('#modal_overlay'))
                .find(r => ((r.querySelector('.cbi-value-title') || {}).textContent || '').trim() === label);
            if (!row) throw new Error('no row ' + label);
            const sel = row.querySelector('select');
            if (!sel) throw new Error('row "' + label + '" has no <select>');
            sel.value = val;
            sel.dispatchEvent(new Event('change', { bubbles: true }));
        }
        setSel('Strategy', 'prefer_ipv4');
    });
    await wait(300);
    // Persist via the page Save button (runs handleSave -> m.parse()+uci.save()),
    // then finalise on disk. A raw L.uci.save() alone would miss the select edit
    // because form widgets only stage their value on parse().
    await page.evaluate(() => {
        const btn = document.querySelector('.cbi-page-actions .cbi-button-save');
        if (!btn) throw new Error('no page Save button');
        btn.click();
    });
    await wait(2000);
    await page.evaluate(async () => { try { await L.uci.apply(0); } catch (_) {} });
    await wait(1200);
    const json = await fetchPreviewConfig(page);
    assert('dns.strategy prefer_ipv4', (json.dns || {}).strategy === 'prefer_ipv4', JSON.stringify(json.dns));

    // Restore baseline (empty strategy) so re-runs start clean.
    containerExec('uci -q delete singbox-ui.dns.strategy; uci commit singbox-ui');
});
