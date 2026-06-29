// 64-outbound-shadowsocks.mjs — required + advanced + emit roundtrip.
import { test, openAddModal, setProtocolInModal, fillField, toggleAdvanced,
         visibleFieldsInActiveTab, saveAndReload, fetchPreviewConfig,
         assert, wait } from './fixtures';

test('outbound:shadowsocks — required + advanced + emit', async ({ page }) => {
    await openAddModal(page, 'outbound', 'ss_out');
    await setProtocolInModal(page, 'shadowsocks', 'Type');
    await wait(500);

    const req = await visibleFieldsInActiveTab(page);
    for (const f of ['Server', 'Server port', 'Method', 'Password']) {
        assert(`ss out required "${f}"`, req.includes(f), req);
    }

    await fillField(page, 'Server',      'ss.example.com');
    await fillField(page, 'Server port', '8388');
    await fillField(page, 'Method',      'aes-256-gcm', { kind: 'select' });
    await fillField(page, 'Password',    'ss-pw');

    await toggleAdvanced(page);
    const adv = await visibleFieldsInActiveTab(page);
    for (const f of ['Plugin', 'Plugin opts', 'UDP over TCP']) {
        assert(`ss out advanced "${f}"`, adv.includes(f), adv);
    }

    await saveAndReload(page);
    const json = await fetchPreviewConfig(page);
    const ob = (json.outbounds || []).find((o: any) => o.tag === 'ss_out');
    assert('ss out emit present',  ob != null, JSON.stringify(json.outbounds));
    assert('ss out emit method',   ob?.method === 'aes-256-gcm');
    assert('ss out emit password', ob?.password === 'ss-pw');
});
