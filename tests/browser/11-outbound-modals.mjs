// 11-outbound-modals.mjs — for each of the 5 outbound protocols (subscription
// is a separate UCI shape — covered in 30-subscription.mjs), seed a section,
// open the modal, verify tabs + basic fields.

import {
    runTest, assert,
    openEditModalBySid, listTabs, visibleFieldsInActiveTab,
    BROWSER_URL, LUCI_USER, LUCI_PASS,
} from './_setup.mjs';
import { execSync } from 'node:child_process';

const SID = '_e2bt_out';

const PROTOCOLS = [
    { type: 'direct',      mustHaveBasic: [],                                                              mustHaveTabs: ['basic', 'dial'] },
    { type: 'shadowsocks', mustHaveBasic: ['Server', 'Server port', 'Method', 'Password'],                 mustHaveTabs: ['basic', 'multiplex', 'dial'] },
    { type: 'vless',       mustHaveBasic: ['Server', 'Server port', 'UUID', 'Flow', 'Network'],            mustHaveTabs: ['basic', 'tls', 'transport', 'multiplex', 'dial'] },
    { type: 'trojan',      mustHaveBasic: ['Server', 'Server port', 'Password'],                           mustHaveTabs: ['basic', 'tls', 'transport', 'multiplex', 'dial'] },
    { type: 'hysteria2',   mustHaveBasic: ['Server', 'Server port', 'Password', 'Uplink Mbps', 'Downlink Mbps'], mustHaveTabs: ['basic', 'tls', 'dial'] },
];

function ssh(cmd) {
    return execSync(`sshpass -p ${LUCI_PASS} ssh -o StrictHostKeyChecking=no ${LUCI_USER}@${new URL(BROWSER_URL).hostname} ${JSON.stringify(cmd)}`, { encoding: 'utf8' });
}

for (const p of PROTOCOLS) {
    ssh(`uci -q delete singbox-ui.${SID}; uci set singbox-ui.${SID}=outbound; uci set singbox-ui.${SID}.enabled=1; uci set singbox-ui.${SID}.type=${p.type}; uci set singbox-ui.${SID}.server=203.0.113.1; uci set singbox-ui.${SID}.server_port=443; uci commit singbox-ui`);

    await runTest(`outbound modal — ${p.type}`, async ({ page }) => {
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
}

ssh(`uci -q delete singbox-ui.${SID}; uci commit singbox-ui`);
console.log('\ndone: 11-outbound-modals');
