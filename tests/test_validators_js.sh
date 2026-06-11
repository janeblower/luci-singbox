#!/bin/sh
# tests/test_validators_js.sh — node-based unit tests for the form
# validators in luci-singbox-ui/htdocs/.../lib/validators.js (Phase 8 / B6).
# Skips when node is unavailable, mirroring tests/test_json_import.sh.
set -e

if ! command -v node >/dev/null 2>&1; then
	echo "SKIP: node not available" >&2
	exit 0
fi

JS=luci-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/lib/validators.js
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/run.js" <<'NODE'
const fs = require('fs');
const vm = require('vm');
const path = require('path');

const src = fs.readFileSync(process.argv[2], 'utf8');

// Strip the LuCI fragment header (use strict + require dsl) and rewrite the
// trailing `return L.Class.extend({...});` into an assignment so we can
// pull the exported namespace out of the sandbox.
const body = src
	.replace(/^'use strict';\s*/, '')
	.replace(/^'require [^']+';\s*/gm, '')
	.replace(/return L\.Class\.extend\((\{[\s\S]*\})\);?\s*$/, '__moduleExports = $1;');

// Capture every console.warn message so we can verify softWarnCongestion
// fires on unknown values without polluting test stdout.
const warnings = [];
const ctxConsole = {
	log: console.log.bind(console),
	error: console.error.bind(console),
	warn: (msg) => warnings.push(String(msg)),
};

// S2-8: provide L.ui.addNotification so any side effect from a "pure" validator
// is observable. A pure validator must NOT touch it (addNotificationCalls stays 0).
let addNotificationCalls = 0;
const sandbox = {
	__moduleExports: null,
	_: (s) => s,
	L: { Class: { extend: (o) => o },
	     ui: { addNotification: () => { addNotificationCalls++; } } },
	E: (t, a, c) => ({ tag: t }),
	console: ctxConsole,
};
const ctx = vm.createContext(sandbox);
vm.runInContext('(function() {' + body + '})();', ctx, { filename: 'validators.js' });

const V = ctx.__moduleExports;
if (!V || typeof V.isPort !== 'function') {
	console.error('FAIL: validators.js did not export the expected namespace');
	process.exit(1);
}

let failures = 0;
function check(label, got, wantTrueOrString) {
	// wantTrueOrString === true -> expect true; string -> expect any non-empty string.
	let ok;
	if (wantTrueOrString === true) {
		ok = (got === true);
	} else if (wantTrueOrString === 'error') {
		ok = (typeof got === 'string' && got.length > 0);
	} else {
		ok = (got === wantTrueOrString);
	}
	if (ok) {
		console.log('  PASS:', label);
	} else {
		console.log('  FAIL:', label, '  got=' + JSON.stringify(got));
		failures++;
	}
}

// --- isPort -----------------------------------------------------------------
check('isPort 8080 valid',       V.isPort(8080),    true);
check('isPort "8080" valid',     V.isPort('8080'),  true);
check('isPort 1 valid',          V.isPort(1),       true);
check('isPort 65535 valid',      V.isPort(65535),   true);
check('isPort 0 invalid',        V.isPort(0),       'error');
check('isPort 65536 invalid',    V.isPort(65536),   'error');
check('isPort "abc" invalid',    V.isPort('abc'),   'error');
check('isPort "-1" invalid',     V.isPort(-1),      'error');
check('isPort "" invalid',       V.isPort(''),      'error');

// --- isUuid -----------------------------------------------------------------
check('isUuid canonical lowercase',
	V.isUuid('550e8400-e29b-41d4-a716-446655440000'), true);
check('isUuid canonical UPPERCASE',
	V.isUuid('550E8400-E29B-41D4-A716-446655440000'), true);
check('isUuid wrong length invalid',
	V.isUuid('550e8400-e29b-41d4-a716-44665544'), 'error');
check('isUuid missing dashes invalid',
	V.isUuid('550e8400e29b41d4a716446655440000'), 'error');
check('isUuid non-hex invalid',
	V.isUuid('zzzzzzzz-e29b-41d4-a716-446655440000'), 'error');
check('isUuid non-string invalid',
	V.isUuid(12345), 'error');

// --- isHost -----------------------------------------------------------------
check('isHost IPv4 valid',          V.isHost('1.2.3.4'),         true);
check('isHost IPv6 valid',          V.isHost('2001:db8::1'),     true);
check('isHost simple domain valid', V.isHost('example.com'),     true);
check('isHost subdomain valid',     V.isHost('a.b-c.example.com'), true);
check('isHost empty invalid',       V.isHost(''),                'error');
check('isHost with space invalid',  V.isHost('not a host!'),     'error');
check('isHost leading dot invalid', V.isHost('.example.com'),    'error');
check('isHost non-string invalid',  V.isHost(null),              'error');

// --- validateAlpn -----------------------------------------------------------
// Per spec C2.2.3: empty ALPN is valid; only validates known protocol names.
check('validateAlpn ["h2"] valid',
	V.validateAlpn(['h2']), true);
check('validateAlpn ["h2","http/1.1"] valid',
	V.validateAlpn(['h2', 'http/1.1']), true);
check('validateAlpn ["h3"] valid',
	V.validateAlpn(['h3']), true);
check('validateAlpn "h2, http/1.1" valid',
	V.validateAlpn('h2, http/1.1'), true);
check('validateAlpn [] valid (empty allowed)',
	V.validateAlpn([]), true);
check('validateAlpn "" valid (empty allowed)',
	V.validateAlpn(''), true);
check('validateAlpn null valid (empty allowed)',
	V.validateAlpn(null), true);
check('validateAlpn [""] valid (blank entries ignored)',
	V.validateAlpn(['']), true);
check('validateAlpn ["unknown"] invalid',
	V.validateAlpn(['unknown']), 'error');
check('validateAlpn ["h2","bogus"] invalid',
	V.validateAlpn(['h2', 'bogus']), 'error');

// --- requiresWsPath ---------------------------------------------------------
check('requiresWsPath (ws, "/path") valid',
	V.requiresWsPath('ws', '/path'), true);
check('requiresWsPath (grpc, "") valid (non-ws)',
	V.requiresWsPath('grpc', ''), true);
check('requiresWsPath (none, "") valid (non-ws)',
	V.requiresWsPath('none', ''), true);
check('requiresWsPath (ws, "") invalid',
	V.requiresWsPath('ws', ''), 'error');
check('requiresWsPath (ws, undefined) invalid',
	V.requiresWsPath('ws', undefined), 'error');

// --- softWarnCongestion -----------------------------------------------------
// All inputs return true; unknown values warn via console.warn.
check('softWarnCongestion cubic returns true',
	V.softWarnCongestion('cubic'), true);
check('softWarnCongestion new_reno returns true',
	V.softWarnCongestion('new_reno'), true);
check('softWarnCongestion bbr returns true',
	V.softWarnCongestion('bbr'), true);
check('softWarnCongestion "" returns true (no warn)',
	V.softWarnCongestion(''), true);
warnings.length = 0;
const r = V.softWarnCongestion('extreme-future-cc');
check('softWarnCongestion unknown returns true',
	r, true);
// S2-8: the validator is now pure — it must NOT emit console.warn either.
check('softWarnCongestion unknown stays silent (pure, S2-8)',
	warnings.length === 0 ? true : warnings.join('|'),
	true);
// isKnownCongestion is the pure classifier the validator now delegates to.
// The harness `check` contract (lines 56-72): want `true` expects strict
// `true`; want `'error'` expects any non-empty string. isKnownCongestion
// returns a BOOLEAN, so assert the boolean result with `=== ` and want `true`.
check('isKnownCongestion classifies bbr as known',
	V.isKnownCongestion('bbr') === true, true);
check('isKnownCongestion classifies junk as unknown',
	V.isKnownCongestion('junk-cc') === false, true);

// --- S2-8: softWarnCongestion must be a PURE validator (no side effects) -----
addNotificationCalls = 0;
const pr = V.softWarnCongestion('definitely-unknown-cc');
check('softWarnCongestion unknown still returns true (pure)', pr, true);
check('softWarnCongestion does NOT call L.ui.addNotification (S2-8)',
	addNotificationCalls === 0 ? true : ('called ' + addNotificationCalls + 'x'),
	true);

if (failures) {
	console.error('test_validators_js: ' + failures + ' failure(s)');
	process.exit(1);
}
console.log('OK');
NODE

node "$TMP/run.js" "$JS"
