#!/bin/sh
# tests/ui/test_ui_surface_guard.sh — invariant guard for goal (a): every
# interactive element in tests/ui/ui_surface.json MUST be exercised by at least
# one tests/browser/*.mjs declaring it in `export const COVERS = [...]`. Runs in
# the CI js-unit (node) job, never in the qemu VM.
set -e
. "$(dirname "$0")/../lib/sb_helpers.sh"
cd "$(dirname "$0")/../.."

if [ "${SINGBOX_TESTS_IN_VM:-0}" = "1" ]; then
    echo "SKIP test_ui_surface_guard: node guard runs in js-unit, not the VM"
    exit 0
fi
if ! command -v node >/dev/null 2>&1; then
    echo "SKIP: node not available" >&2
    exit 0
fi

node - "$PWD" <<'NODE'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];

const registry = JSON.parse(
    fs.readFileSync(path.join(root, 'tests/ui/ui_surface.json'), 'utf8'));
const ids = new Set(registry.map(e => e.id));

function extractCovers(src) {
    const m = src.match(/export\s+const\s+COVERS\s*=\s*\[([\s\S]*?)\]/);
    if (!m) return [];
    return Array.from(m[1].matchAll(/['"]([^'"]+)['"]/g)).map(x => x[1]);
}

const dir = path.join(root, 'tests/browser');
const covered = new Set();
const unknown = [];
for (const f of fs.readdirSync(dir).filter(n => /\.mjs$/.test(n))) {
    const src = fs.readFileSync(path.join(dir, f), 'utf8');
    for (const id of extractCovers(src)) {
        if (!ids.has(id)) unknown.push(`${f}: COVERS unknown id "${id}"`);
        covered.add(id);
    }
}

const missing = registry.map(e => e.id).filter(id => !covered.has(id));
let fail = false;
if (missing.length) {
    fail = true;
    console.error('FAIL: ui_surface ids with NO covering browser test:');
    missing.forEach(id => console.error('  - ' + id));
}
if (unknown.length) {
    fail = true;
    console.error('FAIL: COVERS ids not present in ui_surface.json (typos?):');
    unknown.forEach(u => console.error('  - ' + u));
}
if (fail) process.exit(1);
console.log(`PASS: ui-surface guard — ${ids.size} ids all covered`);
NODE
