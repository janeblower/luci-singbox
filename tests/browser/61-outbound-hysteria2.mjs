// 61-outbound-hysteria2.mjs — required + advanced + emit roundtrip.
import { runTest, openAddModal, setProtocolInModal, fillField, toggleAdvanced,
         visibleFieldsInActiveTab, saveAndReload, fetchPreviewConfig,
         assert, wait } from './_setup.mjs';

await runTest('outbound:hysteria2 — required + advanced + emit', async ({ page }) => {
    await openAddModal(page, 'outbound', 'hy2_out');
    await setProtocolInModal(page, 'hysteria2', 'Type');
    await wait(500);

    const req = await visibleFieldsInActiveTab(page);
    for (const f of ['Server', 'Server port', 'Password']) {
        assert(`hy2 out required "${f}"`, req.includes(f), req);
    }

    await fillField(page, 'Server',      'hy2.example.com');
    await fillField(page, 'Server port', '443');
    await fillField(page, 'Password',    'hy2-out-pw');

    await toggleAdvanced(page);
    const adv = await visibleFieldsInActiveTab(page);
    assert('hy2 out advanced Obfs type', adv.includes('Obfs type'), adv);

    await saveAndReload(page);
    const json = await fetchPreviewConfig(page);
    const ob = (json.outbounds || []).find(o => o.tag === 'hy2_out');
    assert('hy2 out emit present',  ob != null, JSON.stringify(json.outbounds));
    assert('hy2 out emit server',   ob?.server === 'hy2.example.com');
    assert('hy2 out emit port',     ob?.server_port === 443);
    assert('hy2 out emit password', ob?.password === 'hy2-out-pw');
});
