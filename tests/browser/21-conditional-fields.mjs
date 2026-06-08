// 21-conditional-fields.mjs — verify depends-driven conditional visibility:
//   * VLESS outbound: network=udp surfaces packet_encoding
//   * VLESS outbound: transport_type=ws surfaces Path + Host header
//   * VLESS outbound: transport_type=grpc surfaces gRPC service name
//   * VLESS outbound: TLS advanced + Reality enabled surfaces public_key / short_id

import {
    runTest, assert, wait,
    openEditModalBySid, clickTab, toggleAdvanced, visibleFieldsInActiveTab,
    VM_HOST, VM_USER, VM_PASS,
} from './_setup.mjs';
import { execSync } from 'node:child_process';

const SID = '_e2bt_cond';

function ssh(cmd) {
    return execSync(`sshpass -p ${VM_PASS} ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_HOST} ${JSON.stringify(cmd)}`, { encoding: 'utf8' });
}

ssh(`uci -q delete singbox-ui.${SID}; uci set singbox-ui.${SID}=outbound; uci set singbox-ui.${SID}.enabled=1; uci set singbox-ui.${SID}.type=vless; uci set singbox-ui.${SID}.server=203.0.113.1; uci set singbox-ui.${SID}.server_port=443; uci set singbox-ui.${SID}.server_uuid=00000000-0000-0000-0000-000000000001; uci commit singbox-ui`);

async function setSelectByLabel(page, label, value) {
    await page.evaluate(({ label, value }) => {
        const ov = document.getElementById('modal_overlay');
        const row = Array.from(ov.querySelectorAll('.cbi-value'))
            .find(r => (r.querySelector('.cbi-value-title') || {}).textContent === label);
        if (!row) throw new Error(`no row with label "${label}"`);
        const sel = row.querySelector('select');
        if (!sel) throw new Error(`row "${label}" has no <select>`);
        sel.value = value;
        sel.dispatchEvent(new Event('change', { bubbles: true }));
    }, { label, value });
    await wait(500);
}

async function clickFlagByLabel(page, label) {
    await page.evaluate((label) => {
        const ov = document.getElementById('modal_overlay');
        const row = Array.from(ov.querySelectorAll('.cbi-value'))
            .find(r => (r.querySelector('.cbi-value-title') || {}).textContent === label);
        if (!row) throw new Error(`no row with label "${label}"`);
        const cb = row.querySelector('input[type="checkbox"]');
        if (cb) { cb.click(); return; }
        const btn = row.querySelector('button, label');
        if (btn) { btn.click(); return; }
        throw new Error(`no toggle in row "${label}"`);
    }, label);
    await wait(500);
}

await runTest('VLESS outbound: network=udp → packet_encoding visible', async ({ page }) => {
    await openEditModalBySid(page, 'outbound', SID);

    const before = await visibleFieldsInActiveTab(page);
    assert('packet_encoding hidden when network=tcp default',
        !before.includes('Packet encoding'), { before });

    await setSelectByLabel(page, 'Network', 'udp');
    const after = await visibleFieldsInActiveTab(page);
    assert('packet_encoding visible when network=udp',
        after.includes('Packet encoding'), { after });
});

await runTest('VLESS outbound: transport=ws surfaces Path + Host header', async ({ page }) => {
    await openEditModalBySid(page, 'outbound', SID);
    await clickTab(page, 'transport');

    const noneFields = await visibleFieldsInActiveTab(page);
    assert('transport=none → no Path field',
        !noneFields.includes('Path'), { noneFields });

    await setSelectByLabel(page, 'Transport', 'ws');
    const wsFields = await visibleFieldsInActiveTab(page);
    assert('transport=ws → Path visible',
        wsFields.includes('Path'), { wsFields });
    assert('transport=ws → Host header visible',
        wsFields.includes('Host header'), { wsFields });
    assert('transport=ws → gRPC service name absent',
        !wsFields.includes('gRPC service name'), { wsFields });

    await setSelectByLabel(page, 'Transport', 'grpc');
    const grpcFields = await visibleFieldsInActiveTab(page);
    assert('transport=grpc → gRPC service name visible',
        grpcFields.includes('gRPC service name'), { grpcFields });
    assert('transport=grpc → Path absent',
        !grpcFields.includes('Path'), { grpcFields });
});

await runTest('VLESS outbound: reality_enabled → public_key + short_id', async ({ page }) => {
    await openEditModalBySid(page, 'outbound', SID);
    await clickTab(page, 'tls');
    await clickFlagByLabel(page, 'Enable TLS');
    await wait(400);
    await toggleAdvanced(page);
    await clickFlagByLabel(page, 'Enable Reality');

    const fields = await visibleFieldsInActiveTab(page);
    assert('Reality client: public_key visible',
        fields.includes('Reality public key (client)'), { fields });
    assert('Reality client: short_id visible',
        fields.includes('Reality short ID'), { fields });
});

ssh(`uci -q delete singbox-ui.${SID}; uci commit singbox-ui`);
console.log('\ndone: 21-conditional-fields');
