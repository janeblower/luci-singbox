// 53-inbound-trojan.mjs — required + emit roundtrip.
import { test, openAddModal, setProtocolInModal, fillField,
         visibleFieldsInActiveTab, saveAndReload, fetchPreviewConfig,
         assert, wait } from './fixtures';

test('inbound:trojan — required + emit', async ({ page }) => {
    await openAddModal(page, 'inbound', 'trojan_in');
    await setProtocolInModal(page, 'trojan');
    await wait(500);

    const req = await visibleFieldsInActiveTab(page);
    assert('trojan required listen_port', req.includes('Listen port'), req);
    assert('trojan required password',    req.includes('Password'),    req);

    await fillField(page, 'Listen port', '14443');
    await fillField(page, 'Password',    'trojan-test-pw');

    await saveAndReload(page);
    const json = await fetchPreviewConfig(page);
    const ib = (json.inbounds || []).find((i: any) => i.tag === 'trojan_in');
    assert('trojan emit present', ib != null, JSON.stringify(json.inbounds));
    assert('trojan emit listen_port', ib?.listen_port === 14443);
    assert('trojan emit users',
        Array.isArray(ib?.users) && ib.users[0]?.password === 'trojan-test-pw',
        ib?.users);
});
