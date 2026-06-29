// 56-inbound-hysteria2.mjs — required + advanced + emit roundtrip.
import { test, openAddModal, setProtocolInModal, fillField, toggleAdvanced,
         visibleFieldsInActiveTab, saveAndReload, fetchPreviewConfig,
         assert, wait } from './fixtures';

test('inbound:hysteria2 — required + advanced + emit', async ({ page }) => {
    await openAddModal(page, 'inbound', 'hy2_in');
    await setProtocolInModal(page, 'hysteria2');
    await wait(500);

    const req = await visibleFieldsInActiveTab(page);
    assert('hy2 required listen_port', req.includes('Listen port'), req);
    assert('hy2 required password',
        req.includes('Password'), req);

    await fillField(page, 'Listen port',           '15443');
    await fillField(page, 'Password', 'hy2-pw');

    await toggleAdvanced(page);
    const adv = await visibleFieldsInActiveTab(page);
    assert('hy2 advanced Obfs type', adv.includes('Obfs type'), adv);

    await saveAndReload(page);
    const json = await fetchPreviewConfig(page);
    const ib = (json.inbounds || []).find((i: any) => i.tag === 'hy2_in');
    assert('hy2 emit present', ib != null, JSON.stringify(json.inbounds));
    assert('hy2 emit listen_port', ib?.listen_port === 15443);
    assert('hy2 emit users password',
        Array.isArray(ib?.users) && ib.users[0]?.password === 'hy2-pw',
        ib?.users);
});
