// 60-outbound-direct.mjs — advanced surface + emit smoke.
// This is the canonical outbound Add flow: open the outbound grid's Add modal,
// pick a Type, Save, and assert the section emits into preview_config — i.e. it
// genuinely exercises grid.outbound.add.
import { runTest, openAddModal, setProtocolInModal, toggleAdvanced,
         visibleFieldsInActiveTab, saveAndReload, fetchPreviewConfig,
         assert, wait } from './_setup.mjs';

export const COVERS = ["grid.outbound.add"];

await runTest('outbound:direct — advanced surface + emit', async ({ page }) => {
    await openAddModal(page, 'outbound', 'direct_out');
    await setProtocolInModal(page, 'direct', 'Type');
    await wait(500);

    await toggleAdvanced(page);
    const adv = await visibleFieldsInActiveTab(page);
    for (const f of ['Override destination address',
                     'Override destination port',
                     'Proxy protocol version']) {
        assert(`direct outbound advanced "${f}"`, adv.includes(f), adv);
    }

    await saveAndReload(page);
    const json = await fetchPreviewConfig(page);
    const ob = (json.outbounds || []).find(o => o.tag === 'direct_out');
    assert('direct outbound emit present', ob != null, JSON.stringify(json.outbounds));
});
