// 00-page-loads.mjs — smoke: the singbox-ui page renders without errors.
import { runTest, assert, wait, clickTopTab, clickSubTab } from './_setup.mjs';

export const COVERS = ["tab.inbounds", "tab.outbounds", "tab.route", "tab.dns",
    "tab.dashboard", "tab.monitoring", "tab.general",
    "subtab.routerules", "subtab.rulesets", "subtab.routedef"];

await runTest('page loads', async ({ page, errors }) => {
    const title = await page.title();
    assert('title contains Singbox-UI', /Singbox-UI/i.test(title), title);

    const sectionExists = await page.$('#cbi-singbox-ui-inbound');
    assert('inbound section rendered', sectionExists !== null);

    const outboundExists = await page.$('#cbi-singbox-ui-outbound');
    assert('outbound section rendered', outboundExists !== null);

    // Critical errors from prior bugs we explicitly regressed.
    const fatalish = errors.filter(e =>
        /Tab already declared/i.test(e) ||
        /Cannot read properties of undefined/i.test(e)
    );
    assert('no prior-regression errors', fatalish.length === 0, fatalish.join('\n'));
});

await runTest('page: top tabs switch and route sub-tabs switch', async ({ page }) => {
    for (const t of ['inbounds','outbounds','route','dns','dashboard','monitoring','general']) {
        const ok = await clickTopTab(page, t);
        assert('top tab clickable: ' + t, ok, t);
    }
    await clickTopTab(page, 'route');
    for (const st of ['routerules','rulesets','routedef']) {
        const ok = await clickSubTab(page, st);
        assert('route sub-tab clickable: ' + st, ok, st);
    }
});
