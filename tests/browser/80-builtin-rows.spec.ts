// 80-builtin-rows.spec.ts — package-owned rows (`builtin '1'`) render read-only.
//
// This test exists because the unit test could NOT catch the bug it guards. The
// tint was hooked on the <tr> that LuCI master hands to
// renderRowActions(section_id, more_label, trEl) — but the LuCI shipped in
// OpenWrt 25.12 calls it as renderRowActions(section_id): its GridSection
// override drops every argument but the id. So trEl was always undefined on a
// real router, and the row was never tinted. The unit test passed happily,
// because it stubbed the signature from the docs rather than the shipped one.
//
// Only a test against the LuCI that actually runs can see that. It asserts what
// the user sees, not what the code intended:
//   * Edit / Delete are disabled AND actually look dead (the theme only drops a
//     disabled button to opacity .7, which leaves a saturated blue Edit reading
//     as clickable — style.css desaturates them);
//   * the row carries .sb-builtin-row and a background that differs from a
//     user-owned row's;
//   * Enable stays a live toggle, and Export stays clickable — a builtin is
//     read-only, not untouchable.
//
// The seed (tests/browser/fixtures/baseline.uci) ships one: the `wan` outbound.
import { test, assert, wait, clickTopTab } from './fixtures';

export const COVERS = ["grid.builtin.locked"];

test('builtin rows are read-only: greyed Edit/Delete, tinted row, live Enable', async ({ page }) => {
    await clickTopTab(page, 'outbounds');
    await wait(600);

    const row = await page.evaluate(() => {
        const tr = document.querySelector('tr[data-sid="wan"]');
        if (!tr) return null;
        const btn = (label: string) =>
            [...tr.querySelectorAll('button')].find(
                (b) => (b.textContent || '').trim() === label);
        const style = (el: Element | undefined) => {
            if (!el) return null;
            const cs = getComputedStyle(el);
            return { opacity: cs.opacity, filter: cs.filter };
        };
        const cell = tr.querySelector('td.td');
        const other = [...document.querySelectorAll('tr[data-sid]')]
            .find((t) => t !== tr && t.closest('table') === tr.closest('table'));
        const enable = tr.querySelector('input[type="checkbox"]') as HTMLInputElement | null;
        return {
            tinted: tr.classList.contains('sb-builtin-row'),
            cellBg: cell ? getComputedStyle(cell).backgroundColor : null,
            otherCellBg: other?.querySelector('td.td')
                ? getComputedStyle(other.querySelector('td.td') as Element).backgroundColor
                : null,
            editDisabled: btn('Edit')?.disabled ?? null,
            deleteDisabled: btn('Delete')?.disabled ?? null,
            exportDisabled: btn('Export')?.disabled ?? null,
            editStyle: style(btn('Edit')),
            enableDisabled: enable ? enable.disabled : null,
        };
    });

    assert('builtin wan row exists', row !== null, row);
    if (!row) return;

    assert('row carries .sb-builtin-row', row.tinted === true, row);
    assert('Edit is disabled',   row.editDisabled === true, row);
    assert('Delete is disabled', row.deleteDisabled === true, row);

    // Disabled is not enough — it has to READ as disabled. The theme leaves a
    // disabled button at opacity .7 with its colour intact.
    assert('Edit is visibly greyed (desaturated + faded), not just inert',
        row.editStyle !== null
        && row.editStyle.filter.includes('grayscale')
        && Number(row.editStyle.opacity) < 0.7,
        row.editStyle);

    // The row must be distinguishable from a user-owned one. There is no other
    // row in the seed, so assert the tint is a real, non-transparent colour.
    assert('row background is tinted, not transparent',
        row.cellBg !== null && row.cellBg !== 'rgba(0, 0, 0, 0)',
        row.cellBg);

    // Read-only, not untouchable: turning a builtin rule-set on is the whole
    // point of shipping 25 of them, and exporting is a pure read.
    assert('Enable stays a live toggle', row.enableDisabled === false, row);
    assert('Export stays clickable',     row.exportDisabled === false, row);
});
