// tests/browser/run-all.mjs — run every [0-9]*.mjs in lexicographic order.
// Reports each FAIL but continues to the next file; exits 1 if any test
// failed. Used both directly (`bun run-all.mjs`) and from the shell
// harness's per-test loop in tests/test_browser.sh.
import { readdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));

const files = readdirSync(here, { withFileTypes: true })
    .filter(d => d.isFile() && /^\d.*\.mjs$/.test(d.name))
    .map(d => d.name)
    .sort();

let fail = 0;
for (const t of files) {
    console.log(`\n-- ${t} --`);
    const r = spawnSync('bun', [t], { stdio: 'inherit', cwd: here });
    if (r.status !== 0) { console.error(`FAIL: ${t}`); fail = 1; }
}
process.exit(fail);
