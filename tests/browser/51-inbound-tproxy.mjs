// 51-inbound-tproxy.mjs — UI-only check. tproxy requires CAP_NET_ADMIN
// for the nft emit path which the default docker container does NOT have.
// Save-roundtrip is intentionally out of scope; see Task 9 in the plan.
import { runTest, openAddModal, setProtocolInModal,
         visibleFieldsInActiveTab, toggleAdvanced,
         assert, wait } from './_setup.mjs';

await runTest('inbound:tproxy — UI surface (no roundtrip)', async ({ page }) => {
    await openAddModal(page, 'inbound', 'tproxy_in2');
    await setProtocolInModal(page, 'tproxy');
    await wait(500);

    const req = await visibleFieldsInActiveTab(page);
    for (const f of ['Listen port', 'Network',
                     'Interfaces to redirect (nftables)',
                     'Install nftables redirect rules',
                     'Hijack DNS via nftables']) {
        assert(`tproxy field "${f}"`, req.includes(f), req);
    }

    await toggleAdvanced(page);
    const adv = await visibleFieldsInActiveTab(page);
    assert('tproxy advanced tcp_fast_open',
        adv.includes('TCP fast open'), adv);
    assert('tproxy advanced udp_fragment',
        adv.includes('UDP fragment'), adv);
});
