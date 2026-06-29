// 52-inbound-direct.mjs — required + advanced + emit roundtrip.
import { test, openAddModal, setProtocolInModal, fillField, toggleAdvanced,
         visibleFieldsInActiveTab, saveAndReload, fetchPreviewConfig,
         assert, wait } from './fixtures';

test('inbound:direct — required + advanced + emit', async ({ page }) => {
    await openAddModal(page, 'inbound', 'direct_in');
    await setProtocolInModal(page, 'direct');
    await wait(500);

    const req = await visibleFieldsInActiveTab(page);
    assert('direct required', req.includes('Listen port'), req);

    await fillField(page, 'Listen address', '0.0.0.0');
    await fillField(page, 'Listen port',    '17777');

    await toggleAdvanced(page);
    const adv = await visibleFieldsInActiveTab(page);
    assert('direct advanced TCP fast open', adv.includes('TCP fast open'), adv);
    assert('direct advanced UDP fragment',  adv.includes('UDP fragment'),  adv);

    await saveAndReload(page);
    const json = await fetchPreviewConfig(page);
    const ib = (json.inbounds || []).find((i: any) => i.tag === 'direct_in');
    assert('direct emit present', ib != null, JSON.stringify(json.inbounds));
    assert('direct emit listen_port', ib?.listen_port === 17777);
});
