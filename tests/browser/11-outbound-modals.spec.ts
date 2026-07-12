// 11-outbound-modals.mjs — for each of the 5 outbound protocols (subscription
// is a separate UCI shape — covered in 30-subscription.mjs), seed a section,
// open the modal, verify tabs + basic fields.

import {
    test, assert,
    openEditModalBySid, listTabs, visibleFieldsInActiveTab,
    openAddModal, setProtocolInModal, fillField, saveAndReload, containerExec,
} from './fixtures';

const SID = '_e2bt_out';

const PROTOCOLS = [
    { type: 'direct',      mustHaveBasic: [],                                                              mustHaveTabs: ['basic', 'dial'] },
    { type: 'shadowsocks', mustHaveBasic: ['Server', 'Server port', 'Method', 'Password'],                 mustHaveTabs: ['basic', 'multiplex', 'dial'] },
    { type: 'vless',       mustHaveBasic: ['Server', 'Server port', 'UUID', 'Flow', 'Network'],            mustHaveTabs: ['basic', 'tls', 'transport', 'multiplex', 'dial'] },
    { type: 'trojan',      mustHaveBasic: ['Server', 'Server port', 'Password'],                           mustHaveTabs: ['basic', 'tls', 'transport', 'multiplex', 'dial'] },
    { type: 'hysteria2',   mustHaveBasic: ['Server', 'Server port', 'Password', 'Uplink Mbps', 'Downlink Mbps'], mustHaveTabs: ['basic', 'tls', 'dial'] },
];

for (const p of PROTOCOLS) {
    test.describe(p.type, () => {
        test.use({
            uciSeed: `uci -q delete singbox-ui.${SID}; uci set singbox-ui.${SID}=outbound; uci set singbox-ui.${SID}.enabled=1; uci set singbox-ui.${SID}.type=${p.type}; uci set singbox-ui.${SID}.server=203.0.113.1; uci set singbox-ui.${SID}.server_port=443; uci commit singbox-ui`,
        });

        test(`outbound modal — ${p.type}`, async ({ page }) => {
            await openEditModalBySid(page, 'outbound', SID);

            const tabs = await listTabs(page);
            const tabNames = tabs.filter(t => !t.hidden).map(t => t.name);
            for (const expected of p.mustHaveTabs) {
                assert(`${p.type}: tab "${expected}" present`, tabNames.includes(expected), { tabNames });
            }

            const fields = await visibleFieldsInActiveTab(page);
            for (const expected of p.mustHaveBasic) {
                assert(`${p.type}: basic field "${expected}" visible`, fields.includes(expected), { fields });
            }
        });
    });
}

// Group-import fields (sub_import_groups + friends) only render once
// sub_multi=1 flips the subscription into "expand to selector" mode —
// they depend on it, per outbounds.js.
test.describe('subscription — group import', () => {
    test.use({
        uciSeed: `uci -q delete singbox-ui.${SID}; uci set singbox-ui.${SID}=outbound; uci set singbox-ui.${SID}.enabled=1; uci set singbox-ui.${SID}.type=subscription; uci set singbox-ui.${SID}.sub_url=https://sub.example.com/config; uci set singbox-ui.${SID}.sub_multi=1; uci commit singbox-ui`,
    });

    test('outbound modal — subscription group-import field renders', async ({ page }) => {
        await openEditModalBySid(page, 'outbound', SID);

        const present = await page.evaluate(() => {
            const ov = document.getElementById('modal_overlay');
            return !!ov?.querySelector('[data-name="sub_import_groups"]');
        });
        assert('subscription: "sub_import_groups" field present', present);
    });
});

// H3: creating a NEW subscription outbound must pin a distinct, generated
// sub_hwid (per-outbound device identity for Remnawave/Happ-style panels).
// The hook lives on the section-CREATE path (GridSection.handleAdd), not the
// field's load/cfgvalue — an EXISTING subscription's sub_hwid must survive
// opening + saving its modal untouched (NO-migration).
test.describe('subscription — HWID pinned on create', () => {
    const HWID_RE = /^[0-9a-f]{4}(-[0-9a-f]{4}){3}$/;

    test('new subscription outbounds get a generated, distinct sub_hwid each', async ({ page }) => {
        await openAddModal(page, 'outbound', '_h3_sub1');
        await setProtocolInModal(page, 'subscription', 'Type');
        await fillField(page, 'Subscription URL', 'https://sub.example.com/a');
        await saveAndReload(page);

        await openAddModal(page, 'outbound', '_h3_sub2');
        await setProtocolInModal(page, 'subscription', 'Type');
        await fillField(page, 'Subscription URL', 'https://sub.example.com/b');
        await saveAndReload(page);

        const hwid1 = containerExec(`uci -q get singbox-ui._h3_sub1.sub_hwid`).trim();
        const hwid2 = containerExec(`uci -q get singbox-ui._h3_sub2.sub_hwid`).trim();
        assert('sub1 sub_hwid populated + shaped', HWID_RE.test(hwid1), hwid1);
        assert('sub2 sub_hwid populated + shaped', HWID_RE.test(hwid2), hwid2);
        assert('per-outbound hwids differ', hwid1 !== hwid2, { hwid1, hwid2 });
    });
});

test.describe('subscription — existing sub_hwid untouched on save', () => {
    test.use({
        uciSeed: `uci -q delete singbox-ui.${SID}; uci set singbox-ui.${SID}=outbound; uci set singbox-ui.${SID}.enabled=1; uci set singbox-ui.${SID}.type=subscription; uci set singbox-ui.${SID}.sub_url=https://sub.example.com/config; uci set singbox-ui.${SID}.sub_hwid=deadbeef-cafe-0000-1111; uci commit singbox-ui`,
    });

    test('opening + saving an existing subscription leaves sub_hwid untouched', async ({ page }) => {
        await openEditModalBySid(page, 'outbound', SID);
        await saveAndReload(page);
        const hwid = containerExec(`uci -q get singbox-ui.${SID}.sub_hwid`).trim();
        assert('existing sub_hwid unchanged', hwid === 'deadbeef-cafe-0000-1111', hwid);
    });
});
