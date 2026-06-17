// 90-vm-tproxy-roundtrip.mjs — VM-only lane carrier. The real save-roundtrip with
// NET_ADMIN/procd/nft runs in tests/browser/run-vm-lane.sh inside the qemu VM.
// This file exists so the ui-surface guard sees the COVERS tag; when executed by
// the light-container runner it SKIPs (no NET_ADMIN), pointing at the VM lane.
//
// CI hookup: the `browser-vm-lane` step under the `ui` domain (owned by Phase 1)
// runs tests/browser/run-vm-lane.sh inside the qemu VM via tests/run-vm.sh, which
// records the nft result to /tmp/singbox-ui/.vm_lane_nft. Outside the VM this
// carrier SKIPs cleanly so the light-container browser runner is unaffected.
import { assert } from './_setup.mjs';

export const COVERS = ["vm.tproxy_save_roundtrip"];

if (process.env.SINGBOX_TESTS_IN_VM !== '1') {
    console.log('SKIP 90-vm-tproxy-roundtrip: NET_ADMIN/nft only available in the qemu VM lane (run-vm-lane.sh)');
    process.exit(0);
}
// In-VM: assert the nft table was installed by the prior run-vm-lane.sh step,
// recorded to /tmp/singbox-ui/.vm_lane_nft.
import { readFileSync } from 'node:fs';
const ok = (() => { try { return /singbox_ui/.test(readFileSync('/tmp/singbox-ui/.vm_lane_nft','utf8')); } catch(_) { return false; } })();
assert('VM lane installed inet singbox_ui nft table', ok);
