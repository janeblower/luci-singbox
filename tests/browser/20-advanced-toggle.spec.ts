// 20-advanced-toggle.mjs — Bug 4: inbound/outbound builders show ALL fields
// immediately (no "Show advanced fields" toggle). Previously this suite clicked
// the toggle; now it verifies the formerly-advanced fields are visible without
// any toggle, and that no toggle is present. (The toggle still exists for
// DNS/Route — covered separately by the ucode test_advanced_scope.sh.)

import {
    test, assert, wait,
    openEditModalBySid, clickTab, visibleFieldsInActiveTab,
} from './fixtures';

const SID = '_e2bt_adv';

// Seed the section before the page loads (per test) via the uciSeed fixture.
test.use({
    uciSeed: `uci -q delete singbox-ui.${SID}; uci set singbox-ui.${SID}=outbound; uci set singbox-ui.${SID}.enabled=1; uci set singbox-ui.${SID}.type=vless; uci set singbox-ui.${SID}.server=203.0.113.1; uci set singbox-ui.${SID}.server_port=443; uci set singbox-ui.${SID}.server_uuid=00000000-0000-0000-0000-000000000001; uci set singbox-ui.${SID}.tls_enabled=1; uci commit singbox-ui`,
});

test('TLS tab shows advanced fields immediately, no toggle (VLESS outbound)', async ({ page }) => {
    await openEditModalBySid(page, 'outbound', SID);
    await clickTab(page, 'tls');
    await wait(300);

    const fields = await visibleFieldsInActiveTab(page);
    assert('TLS basic visible', fields.includes('Enable TLS') && fields.includes('Server name (SNI)'), { fields });
    // Formerly-advanced fields must be visible WITHOUT any toggle (Bug 4).
    assert('TLS advanced shown immediately — ALPN', fields.includes('ALPN'), { fields });
    assert('TLS advanced shown immediately — Enable Reality', fields.includes('Enable Reality'), { fields });
    assert('TLS advanced shown immediately — Enable uTLS fingerprint', fields.includes('Enable uTLS fingerprint'), { fields });
    // No "Show advanced fields" toggle for outbound anymore.
    assert('No advanced toggle present', !fields.includes('Show advanced fields'), { fields });
});

test('Dial tab shows advanced fields immediately, no toggle (VLESS outbound)', async ({ page }) => {
    await openEditModalBySid(page, 'outbound', SID);
    await clickTab(page, 'dial');
    await wait(300);

    const fields = await visibleFieldsInActiveTab(page);
    assert('Dial basic visible — Bind interface', fields.includes('Bind interface'), { fields });
    assert('Dial advanced shown immediately — Routing mark', fields.includes('Routing mark (fwmark)'), { fields });
    assert('Dial advanced shown immediately — Connect timeout', fields.includes('Connect timeout'), { fields });
    assert('No advanced toggle present', !fields.includes('Show advanced fields'), { fields });
});
