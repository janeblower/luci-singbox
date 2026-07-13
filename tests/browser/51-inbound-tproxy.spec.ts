// 51-inbound-tproxy.spec.ts — UI-only check. tproxy requires CAP_NET_ADMIN
// for the nft emit path which the default docker container does NOT have.
// Save-roundtrip is intentionally out of scope; see Task 9 in the plan.
import { test, openAddModal, setProtocolInModal,
         visibleFieldsInActiveTab, clickTab,
         assert, wait } from './fixtures';

test('inbound:tproxy — UI surface (no roundtrip)', async ({ page }) => {
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

    // The shared listen block (tcp_fast_open, udp_fragment, detour, keep-alive…)
    // has its OWN tab, like dial does for outbounds: `advanced: true` is inert on
    // an inbound (no Show-advanced toggle is injected), so on Basic all twelve
    // would render unconditionally and bury the three fields that matter.
    await clickTab(page, 'listen');
    const lis = await visibleFieldsInActiveTab(page);
    assert('tproxy listen tab tcp_fast_open',
        lis.includes('TCP fast open'), lis);
    assert('tproxy listen tab udp_fragment',
        lis.includes('UDP fragment'), lis);
    assert('tproxy basic tab does NOT carry the listen block',
        !req.includes('TCP fast open'), req);
});
