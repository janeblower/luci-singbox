// 50-inbound-mixed.mjs — required-field + emit smoke for the `mixed` inbound.
import { runTest, openAddModal, setProtocolInModal, fillField,
         visibleFieldsInActiveTab, saveAndReload, fetchPreviewConfig,
         assert, wait } from './_setup.mjs';

await runTest('inbound:mixed — required + emit', async ({ page }) => {
    await openAddModal(page, 'inbound', 'mixed_in');
    await setProtocolInModal(page, 'mixed');
    await wait(500);

    const req = await visibleFieldsInActiveTab(page);
    assert('mixed required surface', req.includes('Listen port'), req);

    await fillField(page, 'Listen address', '127.0.0.1');
    await fillField(page, 'Listen port',    '21080');

    await saveAndReload(page);
    const json = await fetchPreviewConfig(page);
    const ib = (json.inbounds || []).find(i => i.type === 'mixed');
    assert('mixed emit present',       ib != null, JSON.stringify(json.inbounds));
    assert('mixed emit listen_port',   ib?.listen_port === 21080);
    assert('mixed emit listen',        ib?.listen === '127.0.0.1');
});
