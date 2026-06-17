// 74-general.mjs — General tab: ui_compat_only / Cache / Log / Clash API / auto_update.
//
// General is all NamedSections rendered INLINE on the page (no grids/modals):
//   main         -> Flag `ui_compat_only` (UI-only, asserted via UCI)
//   cache        -> descriptor (applyMaterializedNamed) `enabled`/storage/...
//   log          -> Flag `enabled`, ListValue `level`, Value `output`
//   clash_api    -> descriptor (applyMaterializedNamed) `enabled`/listen/port/...
//   subscriptions-> Flag `auto_update` (UI-only, asserted via UCI)
//
// Two seeding wrinkles the live DOM forced (verified against the container):
//  - tests/browser/fixtures/baseline.uci ships NO `main` or `subscriptions`
//    section, so LuCI's NamedSection('main'/'subscriptions') render nothing and
//    the ui_compat_only / auto_update rows are absent. We seed both via UCI +
//    reload so the flags exist to drive. (The shipped etc/config has them; the
//    browser fixture is a trimmed copy.)
//  - Every tab's inline sections live in ONE page DOM; switching tabs toggles
//    `display`. The field helpers therefore scope to VISIBLE page-level rows so
//    a hidden Route "Action"/DNS "Strategy" can't shadow a General field.
//
// Labels are taken VERBATIM from tabs/general.js + the cache/clash_api
// descriptors (ui_label):
//   - ui_compat_only = "Show only parameters compatible with the installed
//     sing-box version"                          (general.js line 16)
//   - Log Enable = "Enable", Level = "Level",
//     Output = "Output file (empty = procd stdout)"  (general.js 31/34/40)
//   - auto_update = "Auto-update subscriptions"  (general.js line 53)
//   - Clash API Enable = "Enable", Port = "Port" (clash_api.uc ui_label)
//   - Cache Enable = "Enable cache file"         (cache.uc ui_label)
// "Enable" appears twice (log + clash_api); clash_api's is disambiguated as the
// Enable row whose section also carries a "Port" title.
//
// Emission paths (generate.uc): log -> json.log ; clash_api ->
// json.experimental.clash_api (the descriptor `port` is UI-only, folded into
// `external_controller` by clash_api.uc post()); cache -> json.experimental
// .cache_file. ui_compat_only / auto_update are UI-only -> assert via UCI.
import { runTest, assert, wait, clickTopTab, containerExec, fetchPreviewConfig } from './_setup.mjs';

export const COVERS = ["tab.general",
    "general.ui_compat_only", "general.cache", "general.log_enabled",
    "general.log_level", "general.log_output", "general.clash_api",
    "general.auto_update"];

// The baseline fixture omits `main`/`subscriptions`; seed them so the
// ui_compat_only and auto_update flags render. Idempotent.
function seedSingletons() {
    containerExec(
        'uci -q get singbox-ui.main >/dev/null 2>&1 || uci set singbox-ui.main=singbox-ui; ' +
        'uci -q get singbox-ui.main.ui_compat_only >/dev/null 2>&1 || uci set singbox-ui.main.ui_compat_only=0; ' +
        'uci -q get singbox-ui.subscriptions >/dev/null 2>&1 || uci set singbox-ui.subscriptions=subscriptions; ' +
        'uci -q get singbox-ui.subscriptions.auto_update >/dev/null 2>&1 || uci set singbox-ui.subscriptions.auto_update=1; ' +
        'uci commit singbox-ui');
}

// Find a VISIBLE page-level `.cbi-value` row by its title and apply `op` to it.
// Visibility matters because every tab's inline sections share one DOM and the
// general tab hides the others via display:none — without the filter a hidden
// Route "Action"/DNS "Strategy" could shadow a General field of the same name.
async function withRow(page, label, op, arg) {
    await page.evaluate(({ label, op, arg }) => {
        const visible = (el) => {
            for (let n = el; n; n = n.parentElement)
                if (n.nodeType === 1 && getComputedStyle(n).display === 'none') return false;
            return true;
        };
        const row = Array.from(document.querySelectorAll('.cbi-value'))
            .filter(r => !r.closest('#modal_overlay') && visible(r))
            .find(r => ((r.querySelector('.cbi-value-title') || {}).textContent || '').trim() === label);
        if (!row) throw new Error('no visible row ' + label);
        if (op === 'flag') {
            const cb = row.querySelector('input[type="checkbox"]');
            if (!cb) throw new Error('row "' + label + '" has no checkbox');
            if (Boolean(cb.checked) !== Boolean(arg)) cb.click();
        } else if (op === 'select') {
            const sel = row.querySelector('select');
            if (!sel) throw new Error('row "' + label + '" has no <select>');
            sel.value = arg;
            sel.dispatchEvent(new Event('change', { bubbles: true }));
        } else { // text
            const inp = row.querySelector('input[type="text"], input[type="password"], input:not([type])');
            if (!inp) throw new Error('row "' + label + '" has no text input');
            inp.focus();
            inp.value = String(arg);
            inp.dispatchEvent(new Event('input', { bubbles: true }));
            inp.dispatchEvent(new Event('change', { bubbles: true }));
        }
    }, { label, op, arg });
    await wait(250);
}

const setFlag = (page, label, on)  => withRow(page, label, 'flag', on);
const setSel  = (page, label, val) => withRow(page, label, 'select', val);
const setText = (page, label, val) => withRow(page, label, 'text', val);

// Check the Clash API section's "Enable" (disambiguated from log's "Enable"
// by a sibling "Port" title in the same section). Reveals Port via
// parent_enabled.
async function enableClashApi(page) {
    await page.evaluate(() => {
        const rows = Array.from(document.querySelectorAll('.cbi-value'))
            .filter(r => !r.closest('#modal_overlay'));
        const clashEnable = rows.find(r => {
            const title = ((r.querySelector('.cbi-value-title') || {}).textContent || '').trim();
            if (title !== 'Enable') return false;
            const sec = r.closest('.cbi-section, fieldset, form') || document;
            return Array.from(sec.querySelectorAll('.cbi-value-title'))
                .some(t => (t.textContent || '').trim() === 'Port');
        });
        if (!clashEnable) throw new Error('no Clash API Enable row');
        const cb = clashEnable.querySelector('input[type="checkbox"]');
        if (cb && !cb.checked) cb.click();
    });
    await wait(400);
}

// Persist via the page Save button so form widgets stage their values in
// m.parse() (a raw L.uci.save() would miss select/flag edits), then finalise
// on disk. Mirrors 73-dns.mjs's DNS Settings save path.
async function savePage(page) {
    await page.evaluate(() => {
        const btn = document.querySelector('.cbi-page-actions .cbi-button-save')
                 || document.querySelector('.cbi-page-actions .cbi-button-apply');
        if (!btn) throw new Error('no page Save button');
        btn.click();
    });
    await wait(2000);
    await page.evaluate(async () => { try { await L.uci.apply(0); } catch (_) {} });
    await wait(1200);
}

async function gotoGeneral(page) {
    await page.reload({ waitUntil: 'networkidle2', timeout: 60000 });
    await wait(2500);
    await clickTopTab(page, 'general');
    await wait(400);
}

await runTest('general: log level/output + ui_compat_only persist to JSON/UCI', async ({ page }) => {
    seedSingletons();
    await gotoGeneral(page);
    await setFlag(page, 'Enable', true);          // log.enabled (reveals Level/Output)
    await setSel(page, 'Level', 'debug');         // general.log_level
    await setText(page, 'Output file (empty = procd stdout)', '/tmp/sb.log'); // general.log_output
    await setFlag(page, 'Show only parameters compatible with the installed sing-box version', true); // ui_compat_only
    await savePage(page);

    // ui_compat_only is UI-only (not in JSON) -> assert via UCI.
    const compat = containerExec('uci -q get singbox-ui.main.ui_compat_only').trim();
    assert('ui_compat_only written to UCI', compat === '1', compat);

    const json = await fetchPreviewConfig(page);
    assert('log.level debug', (json.log || {}).level === 'debug', JSON.stringify(json.log));
    assert('log.output set', (json.log || {}).output === '/tmp/sb.log', JSON.stringify(json.log));

    // Restore (info level, no output, compat off) for clean re-runs.
    containerExec(
        'uci set singbox-ui.log.level=info; ' +
        'uci -q delete singbox-ui.log.output; ' +
        'uci set singbox-ui.main.ui_compat_only=0; ' +
        'uci commit singbox-ui');
});

await runTest('general: clash_api enable+port emits experimental.clash_api', async ({ page }) => {
    seedSingletons();
    await gotoGeneral(page);
    await enableClashApi(page);             // clash_api.enabled (reveals Port)
    await setText(page, 'Port', '19090');   // clash_api port (parent_enabled gated)
    await savePage(page);

    const json = await fetchPreviewConfig(page);
    const exp = json.experimental || {};
    assert('experimental.clash_api present', exp.clash_api != null, JSON.stringify(exp));
    assert('clash_api external_controller carries our port',
        exp.clash_api && /:19090$/.test(String(exp.clash_api.external_controller || '')),
        JSON.stringify(exp.clash_api));

    // Restore baseline: clash_api disabled, port back to 9090.
    containerExec(
        'uci set singbox-ui.clash_api.enabled=0; ' +
        'uci set singbox-ui.clash_api.port=9090; ' +
        'uci commit singbox-ui');
});

await runTest('general: cache enable + auto_update toggle persist', async ({ page }) => {
    seedSingletons();
    await gotoGeneral(page);
    // Cache descriptor `enabled` (json_key) -> json.experimental.cache_file.
    // Baseline already enables cache; (re)assert ON is a no-op but covers the flag.
    await setFlag(page, 'Enable cache file', true);          // general.cache
    await setFlag(page, 'Auto-update subscriptions', false); // general.auto_update (flip off)
    await savePage(page);

    const auto = containerExec('uci -q get singbox-ui.subscriptions.auto_update').trim();
    assert('auto_update written to UCI (0)', auto === '0', auto);

    const json = await fetchPreviewConfig(page);
    const exp = json.experimental || {};
    assert('experimental.cache_file present (cache enabled)', exp.cache_file != null, JSON.stringify(exp));

    // Restore baseline (auto_update back on; cache stays enabled per baseline).
    containerExec(
        'uci set singbox-ui.subscriptions.auto_update=1; ' +
        'uci commit singbox-ui');
});
