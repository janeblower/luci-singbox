// 31-share-link.spec.ts — Import share-link button + modal + JS parser.

import {
    test, assert, wait, dismissModal,
} from './fixtures';

test('share-link: button opens modal', async ({ page }) => {
    const clicked = await page.evaluate(() => {
        const btn = Array.from(document.querySelectorAll('button'))
            .find(b => /import share-link/i.test(b.textContent));
        if (!btn) return { found: false };
        btn.click();
        return { found: true };
    });
    assert('Import share-link button found and clicked', clicked.found, clicked);
    await wait(800);

    const modal = await page.evaluate(() => {
        const ov = document.getElementById('modal_overlay');
        const ta = ov && ov.querySelector('textarea');
        const h = ov && ov.querySelector('h4');
        return {
            hasTextarea: !!ta,
            placeholder: ta ? ta.placeholder : null,
            title: h ? h.textContent : null,
        };
    });
    assert('modal opened with textarea', modal.hasTextarea, modal);
    assert('placeholder mentions all 4 schemes',
        /vless:\/\//.test(modal.placeholder) && /hysteria2:\/\//.test(modal.placeholder) &&
        /ss:\/\//.test(modal.placeholder) && /trojan:\/\//.test(modal.placeholder), modal);

    await dismissModal(page);
});

test('share-link: VLESS URL parsed into JS fields', async ({ page }) => {
    const parsed = await page.evaluate(async () => {
        // Pull the JS module directly via fetch to verify shareLinkImport
        // contract without round-tripping through the UI.
        const src = await fetch('/luci-static/resources/view/singbox-ui/importers/outbound.js').then(r => r.text());
        // The harness inside the page lacks LuCI's L.require — load via Function eval.
        const stub = `
            const _ = s => s;
            const L = { Class: { extend: o => o } };
            const atob = window.atob;
        `;
        const wrapped = '(function(){\n' + stub + '\n' + src
            .replace(/^'use strict';\n/m, '')
            .replace(/^'require [^']+';\n/gm, '')
        + '\n})();';
        const mod = eval(wrapped);
        const r = mod.shareLinkImport('vless://11111111-2222-3333-4444-555555555555@example.com:443?type=tcp#vlsrv');
        return r;
    });
    assert('VLESS parsed OK', parsed && parsed.ok, parsed);
    assert('VLESS type', parsed.fields && parsed.fields.type === 'vless', parsed);
    assert('VLESS server', parsed.fields.server === 'example.com', parsed);
    assert('VLESS uuid', parsed.fields.server_uuid === '11111111-2222-3333-4444-555555555555', parsed);
});

test('share-link: hysteria2 with obfs uses obfs_type/obfs_password keys', async ({ page }) => {
    const parsed = await page.evaluate(async () => {
        const src = await fetch('/luci-static/resources/view/singbox-ui/importers/outbound.js').then(r => r.text());
        const stub = `const _ = s => s; const L = { Class: { extend: o => o } }; const atob = window.atob;`;
        const wrapped = '(function(){\n' + stub + '\n' + src
            .replace(/^'use strict';\n/m, '').replace(/^'require [^']+';\n/gm, '')
        + '\n})();';
        const mod = eval(wrapped);
        return mod.shareLinkImport('hysteria2://hy2pass@h.example:443?obfs=salamander&obfs-password=opass#hy2');
    });
    assert('hy2 type', parsed.fields.type === 'hysteria2', parsed);
    // The HIGH bug from the earlier code review — UCI keys must NOT carry the legacy hysteria2_ prefix.
    assert('hy2 password key (not hysteria2_obfs_password)',
        parsed.fields.obfs_password === 'opass' && !('hysteria2_obfs_password' in parsed.fields), parsed);
    assert('hy2 type key (not hysteria2_obfs_type)',
        parsed.fields.obfs_type === 'salamander' && !('hysteria2_obfs_type' in parsed.fields), parsed);
});
