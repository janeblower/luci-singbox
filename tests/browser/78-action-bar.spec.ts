// 78-action-bar.spec.ts — action-bar buttons + status panel.
import { assert, test, wait } from './fixtures';

export const COVERS = ["actionbar.refresh_subs", "actionbar.refresh_rulesets",
    "actionbar.restart", "actionbar.preview_generated", "actionbar.preview_config",
    "status.panel"];

test('action-bar: every button is present and Preview opens a JSON modal', async ({ page }) => {
    const texts = await page.evaluate(() =>
        Array.from(document.querySelectorAll('.sb-actionbar button')).map(b => b.textContent.trim()));
    ['Refresh subscriptions','Refresh rule-sets','Restart service',
     'Preview generated config','Preview config'].forEach(t =>
        assert('action-bar button: ' + t, texts.some(x => x === t || x.indexOf(t) === 0), texts));

    assert('status panel present', await page.evaluate(() => !!document.querySelector('.sb-status')));

    // Preview config (dry-run) opens a modal with JSON.
    await page.evaluate(() => {
        const b = Array.from(document.querySelectorAll('.sb-actionbar button'))
            .find(x => /^Preview config/.test(x.textContent.trim()));
        b.click();
    });
    await wait(1500);
    const hasModal = await page.evaluate(() => {
        const ov = document.getElementById('modal_overlay');
        return !!(ov && (ov.querySelector('pre,textarea')));
    });
    assert('Preview config opened a JSON modal', hasModal);
});
