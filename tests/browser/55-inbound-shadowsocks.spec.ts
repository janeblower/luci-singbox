// 55-inbound-shadowsocks.mjs — required + advanced + emit roundtrip.
import { test, openAddModal, setProtocolInModal, fillField, toggleAdvanced,
         visibleFieldsInActiveTab, saveAndReload, fetchPreviewConfig,
         assert, wait } from './fixtures';

test('inbound:shadowsocks — required + advanced + emit', async ({ page }) => {
    await openAddModal(page, 'inbound', 'ss_in');
    await setProtocolInModal(page, 'shadowsocks');
    await wait(500);

    const req = await visibleFieldsInActiveTab(page);
    for (const f of ['Listen port', 'Method', 'Password']) {
        assert(`ss required "${f}"`, req.includes(f), req);
    }

    await fillField(page, 'Listen port', '18388');
    await fillField(page, 'Method',      '2022-blake3-aes-128-gcm', { kind: 'select' });
    await fillField(page, 'Password',    'AAAAAAAAAAAAAAAAAAAAAA==');

    await toggleAdvanced(page);
    const adv = await visibleFieldsInActiveTab(page);
    assert('ss advanced Network surfaces', adv.includes('Network'), adv);

    await saveAndReload(page);
    const json = await fetchPreviewConfig(page);
    const ib = (json.inbounds || []).find((i: any) => i.tag === 'ss_in');
    assert('ss emit present', ib != null, JSON.stringify(json.inbounds));
    assert('ss emit listen_port', ib?.listen_port === 18388);
    assert('ss emit method',     ib?.method === '2022-blake3-aes-128-gcm');
});
