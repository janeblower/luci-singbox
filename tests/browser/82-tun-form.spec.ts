// 82-tun-form.spec.ts — the TUN inbound modal, in a real LuCI.
//
// Until task 6 `tun` was missing from SB_INBOUND_PROTOCOLS, so no TUN inbound
// could be created from the UI at all and none of these fields had EVER rendered.
// A unit test cannot stand in for this: it stubs LuCI and therefore validates our
// idea of LuCI. Three things here are LuCI's behaviour, not ours:
//
//   1. the depends chain is TRANSITIVE — auto_route off hides auto_redirect, and
//      hides auto_redirect's own dependants too, because isDependencySatisfied()
//      reads the parent through isActive(). UCI still holds '1' for the children;
//      what makes them vanish is the chain, and only a browser can show that.
//   2. the rule-set picker offers exactly what the backend then emits. The
//      frontend mirror of helpers.ruleset_active() (SbCommon.rulesetActive) is the
//      only thing keeping those two in step, and route_address_set is a WHITELIST
//      ("only these CIDRs enter the tunnel") — a rule-set offered here and pruned
//      there leaves the field empty, and an empty whitelist means the tun captures
//      the ENTIRE address space.
//   3. each choice is offered exactly ONCE. LuCI's value() APPENDS to keylist, and
//      load() runs per render: the devices branch used to accumulate, and the dev
//      stand showed eth0 four times. Invisible in the old datalist; a duplicate
//      ROW in a checkbox dropdown.
import {
    test, expect, assert, openEditModalBySid, dismissModal, containerExec,
    fetchPreviewConfig, wait,
} from './fixtures';

export const COVERS = [
    "inbound.tun.fields",
    "inbound.tun.depends_chain",
    "inbound.tun.ruleset_picker",
    "inbound.tun.device_choices",
];

const TUN = '_tf_tun';
// A SECOND tun, disabled, with route_address_set UNSET — the picker is read from
// this one. ui.Dropdown renders a currently-SET value as an item even when it is
// not among the offered choices (it must: otherwise opening the modal would drop
// what you saved). So the tun that carries the values cannot answer "what does the
// picker OFFER" — only a tun with none can. Disabled, so it claims nothing and is
// not emitted: the preview assertions below stay about TUN alone.
const FRESH = '_tf_fresh';

// A tun that OWNS system routing: tproxy_in gives up its nft rules, so nothing is
// disabled by the exclusive group (that is 81's subject, not ours) and the config
// still builds — generate.uc refuses (rc 3) when both claim it, and preview_config
// would fail with it.
const SEED_TUN =
    `uci set singbox-ui.tproxy_in.nft_rules=0; `
    + `uci set singbox-ui.${TUN}=inbound; `
    + `uci set singbox-ui.${TUN}.enabled=1; `
    + `uci set singbox-ui.${TUN}.protocol=tun; `
    + `uci set singbox-ui.${TUN}.interface_name=singbox-tun; `
    + `uci add_list singbox-ui.${TUN}.address=172.19.0.1/30; `
    + `uci set singbox-ui.${TUN}.stack=system; `
    + `uci set singbox-ui.${TUN}.auto_route=1; `
    + `uci set singbox-ui.${TUN}.auto_redirect=1; `
    + `uci set singbox-ui.${TUN}.auto_redirect_input_mark=0x2023; `
    + `uci add_list singbox-ui.${TUN}.route_address_set=russia_inside; `
    + `uci add_list singbox-ui.${TUN}.route_address_set=discord; `
    + `uci add_list singbox-ui.${TUN}.include_interface=eth0; `
    // russia_inside becomes a PACKAGE-OWNED rule-set, so the built-in master
    // switch (main.default_rulesets) decides whether it is live at all.
    + `uci set singbox-ui.russia_inside.builtin=1; `
    + `uci set singbox-ui.${FRESH}=inbound; `
    + `uci set singbox-ui.${FRESH}.enabled=0; `
    + `uci set singbox-ui.${FRESH}.protocol=tun; `
    + `uci add_list singbox-ui.${FRESH}.address=172.20.0.1/30; `
    + `uci set singbox-ui.${FRESH}.auto_route=1; `
    + `uci commit singbox-ui`;

// One row's state in the open modal, addressed by the stable data-sb-field hook.
async function fieldState(page: import('@playwright/test').Page, field: string) {
    return await page.evaluate((f) => {
        const ov = document.getElementById('modal_overlay');
        const node = ov?.querySelector(`[data-sb-field="${f}"]`);
        if (!node) return null;
        const row = node.closest('.cbi-value') as HTMLElement | null;
        const cb = node.querySelector('input[type="checkbox"]') as HTMLInputElement | null;
        return {
            control: node.getAttribute('data-sb-control'),
            // A hidden dependant is display:none on its ROW, not a missing node.
            visible: row ? getComputedStyle(row).display !== 'none' : false,
            checked: cb ? cb.checked : null,
        };
    }, field);
}

// The values a checkbox dropdown offers, in DOM order, minus the "-- custom --"
// row (data-value="-") that `create: true` adds.
//
// `ul:not(.preview)`, verified against the DOM the container actually renders (not
// the docs): ui.Dropdown gives its list the `dropdown` CLASS only while it is OPEN,
// and on opening it CLONES every selected <li> into a second `ul.preview` (the
// collapsed summary). So `ul.dropdown > li` is empty on a closed widget, and an
// unscoped `li[data-value]` counts the selected ones twice on an open one.
async function choicesOf(page: import('@playwright/test').Page, field: string) {
    return await page.evaluate((f) => {
        const ov = document.getElementById('modal_overlay');
        const node = ov?.querySelector(`[data-sb-field="${f}"]`);
        if (!node) return null;
        return Array.from(node.querySelectorAll('ul:not(.preview) > li[data-value]'))
            .map((li) => li.getAttribute('data-value'))
            .filter((v) => v !== '-');
    }, field);
}

test.describe('the TUN modal', () => {
    test.use({ uciSeed: SEED_TUN });

    test('every field renders, and the exclusive-group winner keeps its checkbox', async ({ page }) => {
        await openEditModalBySid(page, 'inbound', TUN);

        // A list with NO choices stays a DynamicList; a list WITH choices is the
        // checkbox dropdown. 79-cross-cutting's DynamicList coverage rides on
        // `address` being the first kind — keep it that way.
        const address = await fieldState(page, 'address');
        assert('address renders as a DynamicList', address?.control === 'dynamic', address);

        for (const f of ['interface_name', 'stack', 'mtu', 'auto_route', 'auto_redirect']) {
            const st = await fieldState(page, f);
            assert(`${f} renders and is visible`, st?.visible === true, { f, st });
        }
        for (const f of ['route_address_set', 'route_exclude_address_set', 'include_interface']) {
            const st = await fieldState(page, f);
            assert(`${f} is a checkbox dropdown`, st?.control === 'multi', { f, st });
            assert(`${f} is visible`, st?.visible === true, { f, st });
        }

        // tproxy_in gave up nft_rules, so this tun owns the group: its checkbox is
        // live and ticked. (The DEAD side is 81's job.)
        const auto = await fieldState(page, 'auto_route');
        assert('auto_route ticked', auto?.checked === true, auto);

        await dismissModal(page);
    });

    // THE user requirement: "dependent fields appear only when the ones they depend
    // on are selected". Two links deep, which is the part no unit test reaches.
    test('auto_route off hides auto_redirect AND auto_redirect\'s own dependants', async ({ page }) => {
        await openEditModalBySid(page, 'inbound', TUN);

        // Chain: auto_route -> auto_redirect -> auto_redirect_input_mark.
        for (const f of ['auto_redirect', 'auto_redirect_input_mark', 'route_address_set']) {
            const st = await fieldState(page, f);
            assert(`${f} visible while auto_route is on`, st?.visible === true, { f, st });
        }

        // Untick auto_route. LuCI re-evaluates every depends() on the change event.
        await page.evaluate(() => {
            const ov = document.getElementById('modal_overlay');
            const cb = ov?.querySelector('[data-sb-field="auto_route"] input[type="checkbox"]') as HTMLInputElement;
            if (!cb) throw new Error('no auto_route checkbox');
            cb.click();
        });
        await wait(800);

        const hidden: Record<string, unknown> = {};
        for (const f of ['auto_redirect', 'auto_redirect_input_mark', 'route_address_set',
                         'strict_route', 'route_exclude_address_set', 'include_interface'])
            hidden[f] = await fieldState(page, f);

        assert('auto_redirect hidden (direct dependant)',
            (hidden.auto_redirect as any)?.visible === false, hidden.auto_redirect);
        // The transitive one. Its depends is on auto_redirect, which is still '1' in
        // UCI and still '1' in the form model — it is hidden ONLY because its parent
        // is inactive. That is form.js's isDependencySatisfied()/isActive() chain,
        // and this is the only lane that can see it.
        assert('auto_redirect_input_mark hidden TOO (two links up)',
            (hidden.auto_redirect_input_mark as any)?.visible === false,
            hidden.auto_redirect_input_mark);
        for (const f of ['route_address_set', 'strict_route', 'route_exclude_address_set',
                         'include_interface'])
            assert(`${f} hidden`, (hidden[f] as any)?.visible === false, hidden[f]);

        // ...and UCI still holds the children. Nothing was cleared; the fields are
        // merely inactive — which is exactly why the backend needs `requires` on top
        // of `depends`, or it would emit an orphan auto_redirect the core rejects.
        const still = containerExec(`uci -q get singbox-ui.${TUN}.auto_redirect`).trim();
        assert('UCI still carries auto_redirect (depends hides, it does not clear)',
            still === '1', still);

        await dismissModal(page);
    });

    // The devices branch of attachDynamic() had no keylist reset, and LuCI's
    // value() appends — so the choices accumulated once per render. Reopen the
    // modal three times and demand every choice still be offered exactly once.
    test('each netdev choice is offered exactly once, however often the modal is opened', async ({ page }) => {
        for (let i = 0; i < 3; i++) {
            await openEditModalBySid(page, 'inbound', TUN);
            if (i < 2) await dismissModal(page);
        }
        const choices = await choicesOf(page, 'include_interface');
        assert('the netdev picker offers something', (choices?.length ?? 0) > 0, choices);
        const dupes = (choices ?? []).filter((v, i, a) => a.indexOf(v) !== i);
        assert('no choice is offered twice after three renders', dupes.length === 0,
            { choices, dupes });
        await dismissModal(page);
    });
});

// The picker and the generator must agree about which rule-sets are LIVE. The
// frontend mirror (SbCommon.rulesetActive) is the only thing keeping them in step,
// and this asserts the agreement END TO END: what the dropdown offers vs what
// generate.uc actually puts in the config — under both settings of the built-in
// master switch.
test.describe('the rule-set picker offers exactly what generate emits', () => {
    test.describe('built-ins ON (main.default_rulesets unset — NO-migration default)', () => {
        test.use({ uciSeed: SEED_TUN });

        test('the built-in is offered, and it lands in the config', async ({ page }) => {
            await openEditModalBySid(page, 'inbound', FRESH);
            const choices = await choicesOf(page, 'route_address_set');
            expect(choices).toContain('russia_inside');   // builtin '1', master switch unset
            expect(choices).toContain('discord');
            await dismissModal(page);

            const cfg = await fetchPreviewConfig(page) as any;
            const tun = (cfg.inbounds || []).find((i: any) => i.tag === TUN);
            assert('the tun is in the generated config', tun != null, cfg.inbounds);
            expect(tun.route_address_set).toEqual(['russia_inside', 'discord']);
            const tags = (cfg.route?.rule_set || []).map((r: any) => r.tag);
            // referenced_rulesets(): a tag named by the tun MUST be defined, or
            // sing-box dies with "rule-set not found".
            expect(tags).toContain('russia_inside');
            expect(tags).toContain('discord');
        });
    });

    test.describe('built-ins OFF (main.default_rulesets = 0)', () => {
        test.use({
            uciSeed: SEED_TUN
                + `; uci set singbox-ui.main=singbox-ui`
                + `; uci set singbox-ui.main.default_rulesets=0`
                + `; uci commit singbox-ui`,
        });

        test('the built-in is NOT offered, and the backend prunes it out of the config', async ({ page }) => {
            await openEditModalBySid(page, 'inbound', FRESH);
            const choices = await choicesOf(page, 'route_address_set');
            expect(choices).not.toContain('russia_inside');   // the master switch is off
            expect(choices).toContain('discord');             // not a builtin — unaffected
            await dismissModal(page);

            const cfg = await fetchPreviewConfig(page) as any;
            const tun = (cfg.inbounds || []).find((i: any) => i.tag === TUN);
            assert('the tun is in the generated config', tun != null, cfg.inbounds);
            // prune_dead_ruleset_refs() drops the reference; had the picker offered
            // it, the user would have picked a value that silently evaporates — and
            // an EMPTY route_address_set is not "no whitelist", it is no tunnel
            // restriction at all.
            expect(tun.route_address_set).toEqual(['discord']);
            const tags = (cfg.route?.rule_set || []).map((r: any) => r.tag);
            expect(tags).not.toContain('russia_inside');
            expect(tags).toContain('discord');
        });
    });
});
