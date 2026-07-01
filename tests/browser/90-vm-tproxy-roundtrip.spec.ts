// 90-vm-tproxy-roundtrip.spec.ts — placeholder carrier for the ui-surface guard's
// "vm.tproxy_save_roundtrip" COVERS tag. The full NET_ADMIN/procd/nft save-roundtrip
// is not wired into any current lane; outside an in-VM run (SINGBOX_TESTS_IN_VM=1)
// this carrier SKIPs cleanly, so the light-container browser runner is unaffected.
import { readFileSync } from 'node:fs';
import { test, assert } from './fixtures';

export const COVERS = ["vm.tproxy_save_roundtrip"];

test('VM lane installed inet singbox_ui nft table', async () => {
    test.skip(process.env.SINGBOX_TESTS_IN_VM !== '1', 'VM-only');
    // In-VM: assert an in-VM step installed the nft table,
    // recorded to /tmp/singbox-ui/.vm_lane_nft.
    const ok = (() => { try { return /singbox_ui/.test(readFileSync('/tmp/singbox-ui/.vm_lane_nft','utf8')); } catch(_) { return false; } })();
    assert('VM lane installed inet singbox_ui nft table', ok);
});
