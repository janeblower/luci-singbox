// 63-outbound-vless.mjs — required + conditional + emit roundtrip.
import { test, openAddModal, setProtocolInModal, fillField,
         visibleFieldsInActiveTab, saveAndReload, fetchPreviewConfig,
         assert, wait } from './fixtures';

test('outbound:vless — required + conditional + emit', async ({ page }) => {
    await openAddModal(page, 'outbound', 'vless_out');
    await setProtocolInModal(page, 'vless', 'Type');
    await wait(500);

    const req = await visibleFieldsInActiveTab(page);
    for (const f of ['Server', 'Server port', 'UUID']) {
        assert(`vless out required "${f}"`, req.includes(f), req);
    }

    await fillField(page, 'Server',      'vl.example.com');
    await fillField(page, 'Server port', '443');
    await fillField(page, 'UUID',        '11111111-2222-3333-4444-555555555555');

    // Conditional: switching Network to udp should reveal "Packet encoding".
    await fillField(page, 'Network', 'udp', { kind: 'select' });
    await wait(400);
    const afterUdp = await visibleFieldsInActiveTab(page);
    assert('vless out conditional packet_encoding when network=udp',
        afterUdp.includes('Packet encoding'), afterUdp);
    await fillField(page, 'Network', 'tcp', { kind: 'select' });
    await wait(400);
    const afterTcp = await visibleFieldsInActiveTab(page);
    assert('vless out packet_encoding hidden when network=tcp',
        !afterTcp.includes('Packet encoding'), afterTcp);

    await saveAndReload(page);
    const json = await fetchPreviewConfig(page);
    const ob = (json.outbounds || []).find((o: any) => o.tag === 'vless_out');
    assert('vless out emit present', ob != null, JSON.stringify(json.outbounds));
    assert('vless out emit uuid',
        ob?.uuid === '11111111-2222-3333-4444-555555555555');
});
