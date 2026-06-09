// 62-outbound-trojan.mjs — required + emit roundtrip.
import { runTest, openAddModal, setProtocolInModal, fillField,
         visibleFieldsInActiveTab, saveAndReload, fetchPreviewConfig,
         assert, wait } from './_setup.mjs';

await runTest('outbound:trojan — required + emit', async ({ page }) => {
    await openAddModal(page, 'outbound', 'trojan_out');
    await setProtocolInModal(page, 'trojan', 'Type');
    await wait(500);

    const req = await visibleFieldsInActiveTab(page);
    for (const f of ['Server', 'Server port', 'Password']) {
        assert(`trojan out required "${f}"`, req.includes(f), req);
    }

    await fillField(page, 'Server',      'tj.example.com');
    await fillField(page, 'Server port', '443');
    await fillField(page, 'Password',    'tj-pw');

    await saveAndReload(page);
    const json = await fetchPreviewConfig(page);
    const ob = (json.outbounds || []).find(o => o.tag === 'trojan_out');
    assert('trojan out emit present',  ob != null, JSON.stringify(json.outbounds));
    assert('trojan out emit server',   ob?.server === 'tj.example.com');
    assert('trojan out emit password', ob?.password === 'tj-pw');
});
