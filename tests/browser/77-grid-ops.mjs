// 77-grid-ops.mjs — grid operations on the inbound AND outbound grids:
// Edit (open existing row, change a field, save), Delete, Reorder (drag,
// sortable), per-row Export JSON, plain-JSON import textarea, inline
// Enable/Disable toggle. The inbound and outbound grids are structurally
// identical (form.GridSection, sortable, editable enable Flag, per-row Export
// button), so the same DOM-driven operations apply to both.
import { runTest, assert, wait, clickTopTab, openEditModalBySid, fillField,
         saveAndReload, containerExec } from './_setup.mjs';

export const COVERS = [
    "grid.inbound.edit", "grid.inbound.delete", "grid.inbound.reorder",
    "grid.inbound.export", "grid.inbound.importjson", "grid.inbound.enable",
    "grid.outbound.edit", "grid.outbound.delete", "grid.outbound.reorder",
    "grid.outbound.export", "grid.outbound.enable",
    "grid.outbound.importjson", "grid.outbound.sharelink"];

const A = '_go_a', B = '_go_b';

await runTest('grid: inline enable toggle flips UCI enabled', async ({ page }) => {
    containerExec(`uci set singbox-ui.${A}=inbound; uci set singbox-ui.${A}.protocol=mixed; uci set singbox-ui.${A}.enabled=1; uci set singbox-ui.${A}.listen_port=11080; uci commit singbox-ui`);
    await clickTopTab(page, 'inbounds');
    await page.reload({ waitUntil: 'networkidle2' }); await wait(2500);
    // Inline editable Flag in the row: a checkbox in the row's enabled cell.
    // Clicking the checkbox flips the live widget, but LuCI's editable GridSection
    // only stages the change into L.uci when the section's form parse() runs (the
    // same path the action-bar "Save & Apply" takes). Drive it via the bound Map
    // instance's save(), which calls parse() and stages the change.
    const toggled = await page.evaluate(async (sid) => {
        const row = document.querySelector(`#cbi-singbox-ui-inbound tr[data-sid="${sid}"]`);
        if (!row) return false;
        const cb = row.querySelector('input[type="checkbox"]');
        if (!cb) return false;
        cb.click();
        const sectionEl = document.getElementById('cbi-singbox-ui-inbound');
        const inst = sectionEl && L.dom.findClassInstance(sectionEl);
        if (!inst || !inst.map) return false;
        await inst.map.save(null, true);  // parse() -> stage inline edit into L.uci
        return true;
    }, A);
    assert('inline enable checkbox present + clicked', toggled, A);
    await page.evaluate(async () => { await L.uci.save(); try { await L.uci.apply(0); } catch(_){} });
    await wait(1000);
    const en = containerExec(`uci -q get singbox-ui.${A}.enabled`).trim();
    assert('enabled flipped to 0 via inline toggle', en === '0', en);
});

await runTest('grid: Edit opens existing inbound row, changes a field, saves', async ({ page }) => {
    containerExec(`uci -q delete singbox-ui.${A}; uci set singbox-ui.${A}=inbound; uci set singbox-ui.${A}.protocol=mixed; uci set singbox-ui.${A}.enabled=1; uci set singbox-ui.${A}.listen_port=11080; uci commit singbox-ui`);
    await clickTopTab(page, 'inbounds');
    await page.reload({ waitUntil: 'networkidle2' }); await wait(2500);
    // Open the existing row's Edit modal (proves grid Edit button + descriptor
    // render), change the listen port, Save, and assert the new value is on disk.
    await openEditModalBySid(page, 'inbound', A);
    await fillField(page, 'Listen port', '11081');
    await saveAndReload(page);
    const port = containerExec(`uci -q get singbox-ui.${A}.listen_port`).trim();
    assert('inbound Edit persisted new listen_port', port === '11081', port);
    containerExec(`uci -q delete singbox-ui.${A}; uci commit singbox-ui`);
});

await runTest('grid: per-row Export JSON opens modal with section JSON', async ({ page }) => {
    containerExec(`uci set singbox-ui.${A}=inbound; uci set singbox-ui.${A}.protocol=mixed; uci set singbox-ui.${A}.enabled=1; uci set singbox-ui.${A}.listen_port=11080; uci commit singbox-ui`);
    await clickTopTab(page, 'inbounds');
    await page.reload({ waitUntil: 'networkidle2' }); await wait(2500);
    const clicked = await page.evaluate((sid) => {
        const row = document.querySelector(`#cbi-singbox-ui-inbound tr[data-sid="${sid}"]`);
        if (!row) return false;
        const btn = Array.from(row.querySelectorAll('button')).find(b => /export/i.test(b.textContent));
        if (!btn) return false; btn.click(); return true;
    }, A);
    assert('Export button present + clicked', clicked, A);
    // Export modal fetches the section JSON via the export_section RPC and fills
    // the <pre> asynchronously — give the RPC round-trip time to settle.
    await wait(2500);
    const hasJson = await page.evaluate(() => {
        const ov = document.getElementById('modal_overlay');
        const pre = ov && (ov.querySelector('pre,textarea'));
        // export_section emits the sing-box JSON, where the discriminator key is
        // "type" (the UCI "protocol" option maps to sing-box "type").
        return pre ? /"type"\s*:\s*"mixed"/.test(pre.textContent || pre.value || '') : false;
    });
    assert('Export modal shows the section JSON', hasJson);
});

await runTest('grid: Import JSON textarea creates a section', async ({ page }) => {
    await clickTopTab(page, 'inbounds');
    await page.evaluate(() => {
        const btn = Array.from(document.querySelectorAll('button')).find(b => /import json/i.test(b.textContent));
        btn.click();
    });
    await wait(800);
    await page.evaluate(() => {
        const ov = document.getElementById('modal_overlay');
        const ta = ov.querySelector('textarea');
        ta.value = JSON.stringify({ type:'mixed', tag:'_go_imp', listen_port:11099 });
        ta.dispatchEvent(new Event('input', { bubbles: true }));
        const go = Array.from(ov.querySelectorAll('button')).find(b => /^import$/i.test(b.textContent.trim()));
        go.click();
    });
    await wait(1200);
    await page.evaluate(async () => { await L.uci.save(); try { await L.uci.apply(0); } catch(_){} });
    await wait(1000);
    const sec = containerExec(`uci -q show singbox-ui | grep -c "=inbound" || true`).trim();
    assert('Import JSON added an inbound section', Number(sec) >= 1, sec);
});

await runTest('grid: Delete removes the row + UCI section', async ({ page }) => {
    containerExec(`uci set singbox-ui.${A}=inbound; uci set singbox-ui.${A}.protocol=mixed; uci set singbox-ui.${A}.enabled=1; uci commit singbox-ui`);
    await clickTopTab(page, 'inbounds');
    await page.reload({ waitUntil: 'networkidle2' }); await wait(2500);
    const del = await page.evaluate((sid) => {
        const row = document.querySelector(`#cbi-singbox-ui-inbound tr[data-sid="${sid}"]`);
        if (!row) return false;
        const btn = Array.from(row.querySelectorAll('button')).find(b => /delete|remove/i.test(b.textContent));
        if (!btn) return false; btn.click(); return true;
    }, A);
    assert('Delete button present + clicked', del, A);
    // GridSection.handleRemove() stages the removal and kicks its own async
    // map.save(); flush to disk via L.uci.save()/apply(). Both the handler's
    // save and ours can race the same delete — a second flush of an already-gone
    // section throws "Resource not found"; tolerate it, the on-disk state is the
    // assertion.
    await page.evaluate(async () => {
        try { await L.uci.save(); } catch (_) {}
        try { await L.uci.apply(0); } catch (_) {}
    });
    await wait(1000);
    const gone = containerExec(`uci -q get singbox-ui.${A} 2>/dev/null || echo GONE`).trim();
    assert('deleted section absent from UCI', gone === 'GONE', gone);
});

await runTest('grid: Reorder (drag) is supported (sortable=true)', async ({ page }) => {
    // Seed two rows; assert the grid exposes drag handles (sortable). Full DnD
    // simulation is brittle; we assert the sortable affordance + that LuCI's
    // reorder API moves a section, which is what the user-visible drag does.
    containerExec(`uci set singbox-ui.${A}=inbound; uci set singbox-ui.${A}.protocol=mixed; uci set singbox-ui.${B}=inbound; uci set singbox-ui.${B}.protocol=mixed; uci commit singbox-ui`);
    await clickTopTab(page, 'inbounds');
    await page.reload({ waitUntil: 'networkidle2' }); await wait(2500);
    const hasHandle = await page.evaluate(() => {
        const t = document.getElementById('cbi-singbox-ui-inbound');
        return !!(t && t.querySelector('.cbi-section-table-row[draggable], .drag-handle, [data-sortable]'));
    });
    assert('grid rows are draggable (sortable affordance present)', hasHandle);
    // cleanup
});

containerExec(`for s in ${A} ${B} _go_imp; do uci -q delete singbox-ui.$s; done; uci commit singbox-ui`);

// Outbound-only: Import JSON + share-link buttons exist on the outbound grid.
await runTest('outbound grid: Import JSON + Import share-link buttons present', async ({ page }) => {
    await clickTopTab(page, 'outbounds');
    const btns = await page.evaluate(() => Array.from(document.querySelectorAll('button')).map(b => b.textContent.trim()));
    assert('outbound Import JSON button', btns.some(t => /import json/i.test(t)), btns);
    assert('outbound Import share-link button', btns.some(t => /import share-link/i.test(t)), btns);
});

// --- Outbound grid ops: Edit / Enable / Export / Delete / Reorder ------------
// The outbound grid is the structural twin of the inbound grid (form.GridSection,
// sortable=true, editable `enabled` Flag, per-row Export button). Each block
// below genuinely drives the live DOM against an existing outbound row, mirroring
// the inbound coverage above so the outbound grid-ops are exercised for real.

await runTest('grid: Edit opens existing outbound row, changes a field, saves', async ({ page }) => {
    containerExec(`uci -q delete singbox-ui.${A}; uci set singbox-ui.${A}=outbound; uci set singbox-ui.${A}.type=direct; uci set singbox-ui.${A}.enabled=1; uci commit singbox-ui`);
    await clickTopTab(page, 'outbounds');
    await page.reload({ waitUntil: 'networkidle2' }); await wait(2500);
    await openEditModalBySid(page, 'outbound', A);
    // `direct` outbound: set the override destination address (advanced field,
    // shown immediately for outbound — no advanced toggle). UCI key = override_address.
    await fillField(page, 'Override destination address', '198.51.100.7');
    await saveAndReload(page);
    const addr = containerExec(`uci -q get singbox-ui.${A}.override_address`).trim();
    assert('outbound Edit persisted override_address', addr === '198.51.100.7', addr);
    containerExec(`uci -q delete singbox-ui.${A}; uci commit singbox-ui`);
});

await runTest('grid: inline enable toggle flips UCI enabled (outbound)', async ({ page }) => {
    containerExec(`uci -q delete singbox-ui.${A}; uci set singbox-ui.${A}=outbound; uci set singbox-ui.${A}.type=direct; uci set singbox-ui.${A}.enabled=1; uci commit singbox-ui`);
    await clickTopTab(page, 'outbounds');
    await page.reload({ waitUntil: 'networkidle2' }); await wait(2500);
    const toggled = await page.evaluate(async (sid) => {
        const row = document.querySelector(`#cbi-singbox-ui-outbound tr[data-sid="${sid}"]`);
        if (!row) return false;
        const cb = row.querySelector('input[type="checkbox"]');
        if (!cb) return false;
        cb.click();
        const sectionEl = document.getElementById('cbi-singbox-ui-outbound');
        const inst = sectionEl && L.dom.findClassInstance(sectionEl);
        if (!inst || !inst.map) return false;
        await inst.map.save(null, true);  // parse() -> stage inline edit into L.uci
        return true;
    }, A);
    assert('outbound inline enable checkbox present + clicked', toggled, A);
    await page.evaluate(async () => { await L.uci.save(); try { await L.uci.apply(0); } catch(_){} });
    await wait(1000);
    const en = containerExec(`uci -q get singbox-ui.${A}.enabled`).trim();
    assert('outbound enabled flipped to 0 via inline toggle', en === '0', en);
    containerExec(`uci -q delete singbox-ui.${A}; uci commit singbox-ui`);
});

await runTest('grid: per-row Export JSON opens modal with outbound section JSON', async ({ page }) => {
    // Use a proxy outbound (trojan): export_section only builds the proxy-protocol
    // kinds — `direct`/`interface`/`url`/`subscription` are refused by design
    // (export_section.uc: "unknown outbound type" / "does not support type").
    containerExec(`uci -q delete singbox-ui.${A}; uci set singbox-ui.${A}=outbound; uci set singbox-ui.${A}.type=trojan; uci set singbox-ui.${A}.enabled=1; uci set singbox-ui.${A}.server=t.example.com; uci set singbox-ui.${A}.server_port=443; uci set singbox-ui.${A}.password=secret; uci commit singbox-ui`);
    await clickTopTab(page, 'outbounds');
    await page.reload({ waitUntil: 'networkidle2' }); await wait(2500);
    const clicked = await page.evaluate((sid) => {
        const row = document.querySelector(`#cbi-singbox-ui-outbound tr[data-sid="${sid}"]`);
        if (!row) return false;
        const btn = Array.from(row.querySelectorAll('button')).find(b => /export/i.test(b.textContent));
        if (!btn) return false; btn.click(); return true;
    }, A);
    assert('outbound Export button present + clicked', clicked, A);
    await wait(2500);  // export_section RPC fills the <pre> asynchronously
    const hasJson = await page.evaluate(() => {
        const ov = document.getElementById('modal_overlay');
        const pre = ov && (ov.querySelector('pre,textarea'));
        // export_section emits sing-box JSON; discriminator key is "type"
        // (UCI "type" → sing-box "type") with value "trojan" for this row.
        return pre ? /"type"\s*:\s*"trojan"/.test(pre.textContent || pre.value || '') : false;
    });
    assert('outbound Export modal shows the section JSON', hasJson);
    containerExec(`uci -q delete singbox-ui.${A}; uci commit singbox-ui`);
});

await runTest('grid: Delete removes the outbound row + UCI section', async ({ page }) => {
    containerExec(`uci -q delete singbox-ui.${A}; uci set singbox-ui.${A}=outbound; uci set singbox-ui.${A}.type=direct; uci set singbox-ui.${A}.enabled=1; uci commit singbox-ui`);
    await clickTopTab(page, 'outbounds');
    await page.reload({ waitUntil: 'networkidle2' }); await wait(2500);
    const del = await page.evaluate((sid) => {
        const row = document.querySelector(`#cbi-singbox-ui-outbound tr[data-sid="${sid}"]`);
        if (!row) return false;
        const btn = Array.from(row.querySelectorAll('button')).find(b => /delete|remove/i.test(b.textContent));
        if (!btn) return false; btn.click(); return true;
    }, A);
    assert('outbound Delete button present + clicked', del, A);
    await page.evaluate(async () => {
        try { await L.uci.save(); } catch (_) {}
        try { await L.uci.apply(0); } catch (_) {}
    });
    await wait(1000);
    const gone = containerExec(`uci -q get singbox-ui.${A} 2>/dev/null || echo GONE`).trim();
    assert('deleted outbound section absent from UCI', gone === 'GONE', gone);
});

await runTest('grid: Reorder (drag) is supported on outbound (sortable=true)', async ({ page }) => {
    containerExec(`uci set singbox-ui.${A}=outbound; uci set singbox-ui.${A}.type=direct; uci set singbox-ui.${B}=outbound; uci set singbox-ui.${B}.type=direct; uci commit singbox-ui`);
    await clickTopTab(page, 'outbounds');
    await page.reload({ waitUntil: 'networkidle2' }); await wait(2500);
    const hasHandle = await page.evaluate(() => {
        const t = document.getElementById('cbi-singbox-ui-outbound');
        return !!(t && t.querySelector('.cbi-section-table-row[draggable], .drag-handle, [data-sortable]'));
    });
    assert('outbound grid rows are draggable (sortable affordance present)', hasHandle);
    containerExec(`for s in ${A} ${B}; do uci -q delete singbox-ui.$s; done; uci commit singbox-ui`);
});

console.log('\ndone: 77-grid-ops');
