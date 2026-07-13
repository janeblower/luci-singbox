// 52-inbound-direct.mjs — required + advanced + emit roundtrip.
import { test, openAddModal, setProtocolInModal, fillField, clickTab,
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

    // The shared listen block lives on its own tab (see 51-inbound-tproxy), not on
    // Basic — `advanced: true` is inert on an inbound, so Basic would otherwise
    // render all twelve of its fields unconditionally.
    assert('direct basic tab does NOT carry the listen block',
           !req.includes('TCP fast open'), req);
    await clickTab(page, 'listen');
    const lis = await visibleFieldsInActiveTab(page);
    assert('direct listen tab TCP fast open', lis.includes('TCP fast open'), lis);
    assert('direct listen tab UDP fragment',  lis.includes('UDP fragment'),  lis);
    await fillField(page, 'TCP fast open', '1', { kind: 'flag' });

    await saveAndReload(page);
    const json = await fetchPreviewConfig(page);
    const ib = (json.inbounds || []).find((i: any) => i.tag === 'direct_in');
    assert('direct emit present', ib != null, JSON.stringify(json.inbounds));
    assert('direct emit listen_port', ib?.listen_port === 17777);
    // …and a value set on the new tab survives the save->generate round trip.
    assert('direct emit tcp_fast_open', ib?.tcp_fast_open === true, JSON.stringify(ib));
});
