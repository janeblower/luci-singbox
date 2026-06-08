// 00-page-loads.mjs — smoke: the singbox-ui page renders without errors.
import { runTest, assert, wait } from './_setup.mjs';

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
