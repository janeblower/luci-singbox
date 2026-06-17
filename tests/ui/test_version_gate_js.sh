#!/bin/sh
# tests/test_version_gate_js.sh — node-based unit tests for compareVersions and
# applyVersionGate in lib/common.js.
#
# compareVersions(a, b):
#   1.13.0 vs 1.12.5 → 1 (a newer)
#   1.14.0 vs 1.13.0 → 1
#   1.13.0 vs 1.13.0 → 0 (equal)
#   ''     vs 1.13.0 → 0 (fail open — gate nothing when version unknown)
#   1.13.0 vs ''     → 0 (fail open)
#
# Skips when node is unavailable, mirroring test_descriptor_form_dynamic_js.sh.
set -e
. "$(dirname "$0")/../lib/sb_helpers.sh"

if ! command -v node >/dev/null 2>&1; then
	echo "SKIP: node not available" >&2
	exit 0
fi

JS=${SB_VIEW}/lib/common.js
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/run.js" <<'NODE'
const fs = require('fs');
const vm = require('vm');

const src = fs.readFileSync(process.argv[2], 'utf8');

// Strip 'use strict' and require directives, then capture the L.Class.extend
// argument object as the module export — same transform as
// test_descriptor_form_dynamic_js.sh.
const body = src
	.replace(/^'use strict';\s*/, '')
	.replace(/^'require [^']+';\s*/gm, '')
	.replace(/return L\.Class\.extend\((\{[\s\S]*\})\);?\s*$/, '__moduleExports = $1;');

const sandbox = {
	__moduleExports: null,
	_:       (s) => s,
	L:       { Class: { extend: (o) => o } },
	form:    { ListValue: function () {}, Value: function () {} },
	ui:      { showModal: function () {}, hideModal: function () {} },
	uci:     { sections: function () { return []; }, rename: function () {} },
	window:  { navigator: null },
	document: { body: { appendChild: function () {}, removeChild: function () {} },
	            execCommand: function () { return false; } },
	E:       function (tag) { return { tagName: tag.toUpperCase(), classList: { add: function(){}, remove: function(){} },
	           appendChild: function(){}, removeChild: function(){} }; },
	console: console,
	Promise: Promise,
	Object:  Object,
	Array:   Array,
	String:  String,
	parseInt: parseInt,
};
const ctx = vm.createContext(sandbox);
vm.runInContext('(function() {' + body + '})();', ctx, { filename: 'common.js' });

const C = ctx.__moduleExports;
if (!C || typeof C.compareVersions !== 'function') {
	console.error('FAIL: common.js did not export compareVersions');
	process.exit(1);
}

const compareVersions = C.compareVersions;
let failures = 0;

function pass(label) { console.log('  PASS:', label); }
function fail(label, got, expected) {
	console.error('  FAIL:', label, '— got', got, 'expected', expected);
	failures++;
}

function check(label, a, b, expected) {
	const got = compareVersions(a, b);
	if (got === expected) pass(label);
	else fail(label, got, expected);
}

check("1.12.0 < 1.13.0 → -1",  '1.12.0', '1.13.0', -1);
check("1.14.0 > 1.13.0 → 1",   '1.14.0', '1.13.0',  1);
check("1.13.0 == 1.13.0 → 0",  '1.13.0', '1.13.0',  0);
check("'' vs 1.13.0 → 0 (fail open)", '', '1.13.0',  0);
check("1.13.0 vs '' → 0 (fail open)", '1.13.0', '',  0);

if (failures > 0) {
	console.error('FAIL:', failures, 'assertion(s) failed');
	process.exit(1);
}
NODE

node "$TMP/run.js" "$JS"
echo "PASS: test_version_gate_js"
