// 81-transparent-exclusive.spec.ts — exactly ONE inbound may own system routing
// / the firewall: tproxy.nft_rules (our `inet singbox_ui` table + ip rule) vs
// tun.auto_route (sing-box's own policy routing). The loser's checkbox must
// render DEAD, with a caption naming the owner.
//
// This lane is mandatory here, not decorative. A unit test on makeExclusive
// validates our idea of LuCI; only a real render proves the checkbox is actually
// disabled and the caption actually appears. And it is the ONLY place the
// polarity can be observed the way the operator experiences it:
//
//   tproxy.nft_rules  default 1, no json_key  ⇒ UNSET MEANS ON
//   tun.auto_route    default 0 (61534499)    ⇒ UNSET MEANS OFF
//
// The first test is the regression guard. Under the blanket `!== "0"` polarity
// makeExclusive used to apply to every field, the seeded tun — auto_route unset,
// i.e. routing NOTHING — would claim the group, tproxy's checkbox would go dead
// and forced-off, and the router would end up with no interception at all.
import { test, assert, openEditModalBySid, dismissModal } from './fixtures';

export const COVERS = ["inbound.transparent.exclusive"];

const TUN = '_e2bt_tun';

// State of a descriptor field's widget in the open modal, addressed by the
// stable data-sb-field hook (tagField), not by its label text.
async function flagState(page: import('@playwright/test').Page, field: string) {
    return await page.evaluate((f) => {
        const ov = document.getElementById('modal_overlay');
        const node = ov?.querySelector(`[data-sb-field="${f}"]`);
        if (!node) return null;
        const row = node.closest('.cbi-value');
        const cb = node.querySelector('input[type="checkbox"]') as HTMLInputElement | null;
        return {
            rowVisible: row instanceof HTMLElement
                ? getComputedStyle(row).display !== 'none' : false,
            disabled: cb ? cb.disabled : null,
            checked: cb ? cb.checked : null,
            text: (node.textContent || '').trim(),
        };
    }, field);
}

test.describe('tproxy owns it; the tun routes nothing', () => {
    // A tun WITHOUT auto_route, PREPENDED to the config so it is the FIRST
    // inbound UCI hands out. The order is the whole point: ownership goes to the
    // first CLAIMANT, and under a blanket `!== "0"` polarity this tun — which
    // routes nothing — would be it, and would switch tproxy_in's nft rules off.
    // (`uci set` would append it after tproxy_in and the bug would hide.)
    // baseline.uci already ships tproxy_in with nft_rules '1'.
    test.use({
        uciSeed: `{ printf "config inbound '${TUN}'\\n\\toption enabled '1'\\n\\toption protocol 'tun'\\n\\n"; cat /etc/config/singbox-ui; } > /tmp/seed.uci && cp /tmp/seed.uci /etc/config/singbox-ui`,
    });

    test('an unset auto_route does NOT claim system routing', async ({ page }) => {
        await openEditModalBySid(page, 'inbound', 'tproxy_in');
        const nft = await flagState(page, 'nft_rules');
        assert('tproxy nft_rules widget rendered', nft !== null, nft);
        assert('tproxy nft_rules row visible', nft?.rowVisible, nft);
        assert('tproxy nft_rules is NOT disabled by a tun that routes nothing',
            nft?.disabled === false, nft);
        assert('tproxy nft_rules still ticked', nft?.checked === true, nft);
        await dismissModal(page);
    });

    test('the tun\'s auto_route is disabled and names the owner', async ({ page }) => {
        await openEditModalBySid(page, 'inbound', TUN);
        const auto = await flagState(page, 'auto_route');
        assert('tun auto_route widget rendered', auto !== null, auto);
        assert('tun auto_route row visible', auto?.rowVisible, auto);
        assert('tun auto_route DISABLED (tproxy_in owns system routing)',
            auto?.disabled === true, auto);
        assert('tun auto_route forced off', auto?.checked === false, auto);
        assert('caption names the owning inbound',
            (auto?.text || '').includes('tproxy_in'), auto);
        await dismissModal(page);
    });
});

test.describe('the tun owns it once tproxy gives it up', () => {
    test.use({
        uciSeed: `uci -q delete singbox-ui.${TUN}; uci set singbox-ui.${TUN}=inbound; uci set singbox-ui.${TUN}.enabled=1; uci set singbox-ui.${TUN}.protocol=tun; uci set singbox-ui.${TUN}.auto_route=1; uci set singbox-ui.tproxy_in.nft_rules=0; uci commit singbox-ui`,
    });

    test('tproxy nft_rules is disabled and names the tun', async ({ page }) => {
        await openEditModalBySid(page, 'inbound', TUN);
        const auto = await flagState(page, 'auto_route');
        assert('tun auto_route stays live for its owner', auto?.disabled === false, auto);
        assert('tun auto_route ticked', auto?.checked === true, auto);
        await dismissModal(page);

        await openEditModalBySid(page, 'inbound', 'tproxy_in');
        const nft = await flagState(page, 'nft_rules');
        assert('tproxy nft_rules DISABLED (the tun owns system routing)',
            nft?.disabled === true, nft);
        assert('tproxy nft_rules forced off', nft?.checked === false, nft);
        assert('caption names the owning inbound', (nft?.text || '').includes(TUN), nft);
        await dismissModal(page);
    });
});
