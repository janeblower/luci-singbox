// 50-inbound-mixed.mjs — required-field + emit smoke for the `mixed` inbound.
// This is the canonical inbound Add flow: open the grid's Add modal, pick a
// protocol, fill required fields, Save, and assert the section emits into
// preview_config — i.e. it genuinely exercises grid.inbound.add.
import { test, openAddModal, setProtocolInModal, fillField,
         visibleFieldsInActiveTab, saveAndReload, fetchPreviewConfig,
         assert, wait } from './fixtures';

export const COVERS = ["grid.inbound.add"];

test('inbound:mixed — required + emit', async ({ page }) => {
    await openAddModal(page, 'inbound', 'mixed_in');
    await setProtocolInModal(page, 'mixed');
    await wait(500);

    const req = await visibleFieldsInActiveTab(page);
    assert('mixed required surface', req.includes('Listen port'), req);

    await fillField(page, 'Listen address', '127.0.0.1');
    await fillField(page, 'Listen port',    '21080');

    await saveAndReload(page);
    const json = await fetchPreviewConfig(page);
    const ib = (json.inbounds || []).find((i: any) => i.type === 'mixed');
    assert('mixed emit present',       ib != null, JSON.stringify(json.inbounds));
    assert('mixed emit listen_port',   ib?.listen_port === 21080);
    assert('mixed emit listen',        ib?.listen === '127.0.0.1');
});
