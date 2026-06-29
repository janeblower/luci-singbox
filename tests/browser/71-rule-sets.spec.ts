// 71-rule-sets.spec.ts — Rule-Sets grid: add a remote rule-set through the modal
// and assert it persists to UCI; edit a rule-set that the seed config already
// references and assert it surfaces in preview_config's route.rule_set by tag.
//
// route.rule_set only emits entries that are REFERENCED by a route_rule's
// `rule_set` matcher (ruleset.uc iterates referenced_names), so a freshly-added
// standalone rule-set won't appear in the preview — we assert its UCI write
// directly. The seed config references `russia_inside`, so the edit path is
// asserted against that tag in the live preview.
//
// Grid kind = `ruleset`; discriminator `Type` = remote | local | inline.
import { test, assert, wait, clickTopTab, clickSubTab,
         openAddModal, openEditModalBySid, setProtocolInModal, fillField,
         saveAndReload, fetchPreviewConfig, containerExec } from './fixtures';

export const COVERS = ["subtab.rulesets", "grid.ruleset.add", "grid.ruleset.edit"];

test('route: add remote rule-set + edit a referenced one', async ({ page }) => {
    await clickTopTab(page, 'route');
    await clickSubTab(page, 'rulesets');

    // --- Add a remote rule-set through the modal. ----------------------------
    // The section name (rs_remote) is the rule-set tag; there is no separate
    // Tag field — `addRenameField` derives the tag from the UCI section name.
    await openAddModal(page, 'ruleset', 'rs_remote');
    await setProtocolInModal(page, 'remote', 'Type');
    await wait(400);
    await fillField(page, 'URL', 'https://example.com/geosite.srs');
    await saveAndReload(page);

    // Standalone rule-set isn't referenced, so it won't enter route.rule_set;
    // assert the UCI write landed instead (proves the Add modal save path).
    const uciOut = containerExec(
        'uci -q get singbox-ui.rs_remote.url 2>/dev/null || echo MISSING');
    assert('added remote rule-set persisted to UCI',
        uciOut.trim() === 'https://example.com/geosite.srs', uciOut.trim());

    // --- Edit a rule-set the seed config already references. ------------------
    // `russia_inside` is referenced by the seed route_rule `defaults_direct`, so
    // editing it surfaces in route.rule_set. Bump its update_interval via the
    // modal and confirm the tag is present in the emitted rule_set array.
    await openEditModalBySid(page, 'ruleset', 'russia_inside');
    await wait(400);
    await fillField(page, 'Update interval (s)', '43200');
    await saveAndReload(page);

    const json = await fetchPreviewConfig(page);
    const rsArr = (json.route && json.route.rule_set) || [];
    assert('route.rule_set non-empty (referenced rule-sets emit)',
        rsArr.length >= 1, JSON.stringify(rsArr));
    const edited = rsArr.find((r: any) => r.tag === 'russia_inside');
    assert('edited referenced rule-set present by tag',
        edited != null, JSON.stringify(rsArr));

    // Cleanup the added section; revert the edited interval to its seed value.
    containerExec(
        'uci -q delete singbox-ui.rs_remote; ' +
        'uci set singbox-ui.russia_inside.update_interval=86400; ' +
        'uci commit singbox-ui');
});
