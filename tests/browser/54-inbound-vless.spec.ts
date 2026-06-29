// 54-inbound-vless.mjs — required + single-user UUID + emit.
import { test, openAddModal, setProtocolInModal, fillField,
         visibleFieldsInActiveTab, saveAndReload, fetchPreviewConfig,
         assert, wait } from './fixtures';

test('inbound:vless — required + single-user + emit', async ({ page }) => {
    await openAddModal(page, 'inbound', 'vless_in');
    await setProtocolInModal(page, 'vless');
    await wait(500);

    const req = await visibleFieldsInActiveTab(page);
    assert('vless required listen_port', req.includes('Listen port'), req);
    assert('vless UUID field surfaced',
        req.includes('UUID (single-user)'), req);

    await fillField(page, 'Listen port', '11443');
    await fillField(page, 'UUID (single-user)',
        '11111111-2222-3333-4444-555555555555');

    await saveAndReload(page);
    const json = await fetchPreviewConfig(page);
    const ib = (json.inbounds || []).find((i: any) => i.tag === 'vless_in');
    assert('vless emit present', ib != null, JSON.stringify(json.inbounds));
    assert('vless emit listen_port', ib?.listen_port === 11443);
    assert('vless emit user uuid',
        Array.isArray(ib?.users)
        && ib.users[0]?.uuid === '11111111-2222-3333-4444-555555555555',
        ib?.users);
});
