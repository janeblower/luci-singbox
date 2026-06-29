// 70-route-rules.mjs — Route Rules grid: add a default rule (domain matcher +
// route action), save, assert route.rules emits in preview_config; then edit a
// logical rule that references the default rule and assert it emits too.
//
// Grid kind = section type `route_rule`; the discriminator field is `Type`
// (default | logical), NOT `Protocol`. Action/Outbound live on the `action`
// modal tab, so we clickTab into it before filling them. A default rule with
// action=route but no outbound is DROPPED by route.uc (action_ok), so the
// default rule MUST route to a defined outbound — the seed config ships
// `direct_wan`, which we use.
import { test, assert, wait, clickTopTab, clickSubTab,
         openAddModal, openEditModalBySid, setProtocolInModal, fillField,
         clickTab, saveAndReload, fetchPreviewConfig, containerExec } from './fixtures';

export const COVERS = ["tab.route", "subtab.routerules",
    "grid.route_rule.add", "grid.route_rule.edit", "grid.route_rule.logical"];

test('route: add default rule + logical rule, emit route.rules', async ({ page }) => {
    await clickTopTab(page, 'route');
    await clickSubTab(page, 'routerules');

    // --- Add a Default rule: match a domain, route to `direct_wan`. ----------
    await openAddModal(page, 'route_rule', 'rr_default');
    await setProtocolInModal(page, 'default', 'Type');
    await wait(400);
    // Match tab is active first; `domain` field label = "Domain".
    await fillField(page, 'Domain', 'example.com');
    // Action tab → action=route, outbound=direct_wan (exists in seed config).
    await clickTab(page, 'action');
    await fillField(page, 'Action', 'route', { kind: 'select' });
    await wait(300);
    await fillField(page, 'Outbound', 'direct_wan', { kind: 'select' });
    await saveAndReload(page);

    let json = await fetchPreviewConfig(page);
    let rr = (json.route && json.route.rules) || [];
    assert('route.rules present after default-rule add', rr.length >= 1, JSON.stringify(rr));
    const ours = rr.find((r: any) => Array.isArray(r.domain)
        ? r.domain.includes('example.com')
        : r.domain === 'example.com');
    assert('default rule emits our domain matcher', ours != null, JSON.stringify(rr));
    assert('default rule routes to direct_wan',
        ours && ours.outbound === 'direct_wan', JSON.stringify(ours));

    // --- Edit a logical rule that references the default rule. ---------------
    // Seed a logical route_rule via UCI (the grid Edit path is what we exercise);
    // referencing rr_default makes route.uc inline it as a sub-rule. We then open
    // the Edit modal to prove the grid Edit button + descriptor render work, and
    // assert the logical rule emits with our sub-rule inlined.
    containerExec(
        'uci -q delete singbox-ui.rr_logical; ' +
        'uci set singbox-ui.rr_logical=route_rule; ' +
        'uci set singbox-ui.rr_logical.enabled=1; ' +
        'uci set singbox-ui.rr_logical.type=logical; ' +
        'uci set singbox-ui.rr_logical.mode=or; ' +
        'uci add_list singbox-ui.rr_logical.rules=rr_default; ' +
        'uci set singbox-ui.rr_logical.action=route; ' +
        'uci set singbox-ui.rr_logical.outbound=direct_wan; ' +
        'uci commit singbox-ui');

    // Reload so the freshly-seeded logical row renders in the grid.
    await page.reload({ waitUntil: 'networkidle', timeout: 60000 });
    await wait(2500);
    await clickTopTab(page, 'route');
    await clickSubTab(page, 'routerules');
    // Edit button confirms the logical grid row renders + modal opens cleanly.
    await openEditModalBySid(page, 'route_rule', 'rr_logical');
    await wait(400);

    json = await fetchPreviewConfig(page);
    rr = (json.route && json.route.rules) || [];
    const logical = rr.find((r: any) => r.type === 'logical');
    assert('logical rule emits with type=logical', logical != null, JSON.stringify(rr));
    assert('logical rule inlines its sub-rules',
        logical && Array.isArray(logical.rules) && logical.rules.length >= 1,
        JSON.stringify(logical));

    // Cleanup seeded sections so re-runs start clean.
    containerExec('uci -q delete singbox-ui.rr_logical; ' +
                  'uci -q delete singbox-ui.rr_default; uci commit singbox-ui');
});
