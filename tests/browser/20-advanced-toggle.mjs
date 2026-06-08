// 20-advanced-toggle.mjs — click "Show advanced fields" on each tab that
// carries advanced fields, verify hidden fields become visible after toggle.

import {
    runTest, assert, wait,
    openEditModalBySid, clickTab, toggleAdvanced, visibleFieldsInActiveTab,
    containerExec,
} from './_setup.mjs';

const SID = '_e2bt_adv';

containerExec(`uci -q delete singbox-ui.${SID}; uci set singbox-ui.${SID}=outbound; uci set singbox-ui.${SID}.enabled=1; uci set singbox-ui.${SID}.type=vless; uci set singbox-ui.${SID}.server=203.0.113.1; uci set singbox-ui.${SID}.server_port=443; uci set singbox-ui.${SID}.server_uuid=00000000-0000-0000-0000-000000000001; uci set singbox-ui.${SID}.tls_enabled=1; uci commit singbox-ui`);

await runTest('advanced toggle on TLS tab (VLESS outbound)', async ({ page }) => {
    await openEditModalBySid(page, 'outbound', SID);
    await clickTab(page, 'tls');

    const before = await visibleFieldsInActiveTab(page);
    assert('TLS basic visible', before.includes('Enable TLS') && before.includes('Server name (SNI)'), { before });
    assert('TLS advanced hidden by default — ALPN', !before.includes('ALPN'), { before });
    assert('TLS advanced hidden by default — Enable Reality', !before.includes('Enable Reality'), { before });

    await toggleAdvanced(page);
    await wait(600);

    const after = await visibleFieldsInActiveTab(page);
    assert('TLS advanced shown — ALPN', after.includes('ALPN'), { after });
    assert('TLS advanced shown — Enable Reality', after.includes('Enable Reality'), { after });
    assert('TLS advanced shown — Enable uTLS fingerprint', after.includes('Enable uTLS fingerprint'), { after });
});

await runTest('advanced toggle on Dial tab (VLESS outbound)', async ({ page }) => {
    await openEditModalBySid(page, 'outbound', SID);
    await clickTab(page, 'dial');

    const before = await visibleFieldsInActiveTab(page);
    assert('Dial basic visible — Bind interface', before.includes('Bind interface'), { before });
    assert('Dial advanced hidden — Routing mark', !before.includes('Routing mark (fwmark)'), { before });

    await toggleAdvanced(page);
    await wait(600);

    const after = await visibleFieldsInActiveTab(page);
    assert('Dial advanced shown — Routing mark', after.includes('Routing mark (fwmark)'), { after });
    assert('Dial advanced shown — Connect timeout', after.includes('Connect timeout'), { after });
});

containerExec(`uci -q delete singbox-ui.${SID}; uci commit singbox-ui`);
console.log('\ndone: 20-advanced-toggle');
