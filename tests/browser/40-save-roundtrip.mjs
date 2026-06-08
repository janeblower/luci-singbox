// 40-save-roundtrip.mjs — seed a VLESS outbound through UCI (simulating
// what Save & Apply would write), trigger sing-box restart, then verify:
//   * ubus preview_config returns valid JSON with our outbound
//   * logread has no FATAL / panic lines
//   * nft list shows the singbox table (sanity)
//
// We don't drive the actual UI Save button to keep the test deterministic —
// the UI write path is covered by 10/11/20/21 (everything before Save).

import { assert, BROWSER_URL, LUCI_USER, LUCI_PASS } from './_setup.mjs';
import { execSync } from 'node:child_process';

const SID = '_e2bt_save';

function ssh(cmd) {
    return execSync(`sshpass -p ${LUCI_PASS} ssh -o StrictHostKeyChecking=no ${LUCI_USER}@${new URL(BROWSER_URL).hostname} ${JSON.stringify(cmd)}`, { encoding: 'utf8' });
}

console.log('\n=== save-roundtrip: seed VLESS outbound and apply ===');

ssh(`uci -q delete singbox-ui.${SID}; uci set singbox-ui.${SID}=outbound; uci set singbox-ui.${SID}.enabled=1; uci set singbox-ui.${SID}.type=vless; uci set singbox-ui.${SID}.server=203.0.113.50; uci set singbox-ui.${SID}.server_port=8443; uci set singbox-ui.${SID}.server_uuid=11111111-2222-3333-4444-555555555555; uci set singbox-ui.${SID}.tls_enabled=1; uci set singbox-ui.${SID}.tls_server_name=test.example.com; uci commit singbox-ui`);

// Force a regenerate + restart via the same RPC path the UI uses.
const generateOut = ssh(`ubus call singbox-ui generate 2>&1 | head -20`);
console.log('generate:', generateOut.trim().slice(0, 200));

const restartOut = ssh(`ubus call singbox-ui restart 2>&1; sleep 2`);
console.log('restart:', restartOut.trim().slice(0, 200));

// 1. preview_config returns our outbound.
const preview = JSON.parse(ssh(`ubus call singbox-ui preview_config 2>/dev/null`));
assert('preview_config has status ok',
    preview.status === 'ok', preview.status);
const cfg = JSON.parse(preview.content);
const ourOutbound = (cfg.outbounds || []).find(o => o.tag === SID);
assert('our VLESS outbound present', !!ourOutbound, cfg.outbounds);
assert('VLESS server matches', ourOutbound && ourOutbound.server === '203.0.113.50', ourOutbound);
assert('VLESS uuid matches', ourOutbound && ourOutbound.uuid === '11111111-2222-3333-4444-555555555555', ourOutbound);
assert('VLESS tls.enabled', ourOutbound && ourOutbound.tls && ourOutbound.tls.enabled === true, ourOutbound);
assert('VLESS tls.server_name', ourOutbound && ourOutbound.tls.server_name === 'test.example.com', ourOutbound);

// 2. logread has no FATAL/panic since restart.
const log = ssh(`logread -e sing-box | tail -50 2>&1`);
const bad = log.split('\n').filter(l => /FATAL|panic|Traceback|fail to start/i.test(l));
assert('logread has no FATAL/panic in last 50 sing-box lines', bad.length === 0, bad.join('\n'));

// 3. nft list ruleset contains singbox table.
const nft = ssh(`nft list ruleset 2>/dev/null | grep -E '^table .*singbox' | head -1`);
assert('nft singbox table present', nft.trim().length > 0, nft);

// Cleanup.
ssh(`uci -q delete singbox-ui.${SID}; uci commit singbox-ui; ubus call singbox-ui generate >/dev/null 2>&1; ubus call singbox-ui restart >/dev/null 2>&1`);
console.log('\ndone: 40-save-roundtrip');
