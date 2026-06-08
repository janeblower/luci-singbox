// 10-inbound-modals.mjs — for each of the 7 inbound protocols, seed a UCI
// section, open its Edit modal, switch protocol if needed, and verify the
// expected basic-tab fields surface plus the right set of shared tabs.

import {
    runTest, assert, wait,
    openEditModalBySid, setProtocolInModal, listTabs, visibleFieldsInActiveTab,
    containerExec,
} from './_setup.mjs';

const SID = '_e2bt_in';  // unique per-run section name; cleaned by snapshot/restore

const PROTOCOLS = [
    { proto: 'direct',      mustHaveBasic: ['Listen address', 'Listen port', 'Network'],                                     mustHaveTabs: ['basic'] },
    { proto: 'tproxy',      mustHaveBasic: ['Listen address', 'Listen port', 'Network'],                                     mustHaveTabs: ['basic'] },
    { proto: 'mixed',       mustHaveBasic: ['Listen address', 'Listen port', 'Users (username:password)'],                   mustHaveTabs: ['basic'] },
    { proto: 'shadowsocks', mustHaveBasic: ['Listen address', 'Listen port', 'Method', 'Password'],                          mustHaveTabs: ['basic', 'multiplex'] },
    { proto: 'vless',       mustHaveBasic: ['Listen address', 'Listen port', 'Users (name:uuid[:flow])', 'UUID (single-user)'], mustHaveTabs: ['basic', 'tls', 'transport', 'multiplex'] },
    { proto: 'trojan',      mustHaveBasic: ['Listen address', 'Listen port', 'Password'],                                    mustHaveTabs: ['basic', 'tls', 'transport', 'multiplex'] },
    { proto: 'hysteria2',   mustHaveBasic: ['Listen address', 'Listen port', 'Uplink Mbps', 'Downlink Mbps'],                mustHaveTabs: ['basic', 'tls'] },
];

for (const p of PROTOCOLS) {
    // Seed via UCI so the modal opens with the right protocol selected.
    containerExec(`uci -q delete singbox-ui.${SID}; uci set singbox-ui.${SID}=inbound; uci set singbox-ui.${SID}.enabled=1; uci set singbox-ui.${SID}.protocol=${p.proto}; uci set singbox-ui.${SID}.listen_port=12345; uci commit singbox-ui`);

    await runTest(`inbound modal — ${p.proto}`, async ({ page }) => {
        await openEditModalBySid(page, 'inbound', SID);

        const tabs = await listTabs(page);
        const tabNames = tabs.filter(t => !t.hidden).map(t => t.name);
        for (const expected of p.mustHaveTabs) {
            assert(`${p.proto}: tab "${expected}" present and not hidden`, tabNames.includes(expected), { tabNames });
        }

        const fields = await visibleFieldsInActiveTab(page);
        for (const expected of p.mustHaveBasic) {
            assert(`${p.proto}: basic field "${expected}" visible`, fields.includes(expected), { fields });
        }
    });
}

// Cleanup at the end.
containerExec(`uci -q delete singbox-ui.${SID}; uci commit singbox-ui`);
console.log('\ndone: 10-inbound-modals');
