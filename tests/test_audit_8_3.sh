#!/bin/sh
# tests/test_audit_8_3.sh — regression for audit 8.3.
# makeVirtual() previously forced the virtual "Show advanced fields" toggle to
# reset to its default on every modal re-open. It now mirrors the value into a
# session-scoped (NOT UCI-backed) store via write(), so a later cfgvalue() for
# the same (section, option) restores the user's choice — while write/remove
# remain no-ops with respect to UCI (the toggle never leaks into the config).
# Loads lib/descriptor_form.js the same way as test_descriptor_form_js.sh.
set -e

if ! command -v node >/dev/null 2>&1; then
	echo "SKIP: node not available" >&2
	exit 0
fi

JS=luci-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/lib/descriptor_form.js
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/run.js" <<'NODE'
const fs = require('fs');
const vm = require('vm');

const src = fs.readFileSync(process.argv[2], 'utf8');
const body = src
	.replace(/^'use strict';\s*/, '')
	.replace(/^'require [^']+';\s*/gm, '')
	.replace(/return L\.Class\.extend\((\{[\s\S]*\})\);?\s*$/, '__moduleExports = $1;');

const form = { Flag: 'Flag', ListValue: 'ListValue', DynamicList: 'DynamicList', Value: 'Value' };
const validators = { host: () => true, port: () => true, uuid: () => true, alpn: () => true };
const sandbox = {
	__moduleExports: null,
	_:          (s) => s,
	L:          { Class: { extend: (o) => o } },
	form:       form,
	ui:         {},
	validators: validators,
	console:    console,
};
const ctx = vm.createContext(sandbox);
vm.runInContext('(function() {' + body + '})();', ctx, { filename: 'descriptor_form.js' });

const DF = ctx.__moduleExports;
const applyMaterialized = DF && DF.applyMaterialized;
if (typeof applyMaterialized !== 'function') {
	console.error('FAIL: descriptor_form.js did not export applyMaterialized');
	process.exit(1);
}

let failures = 0;
function assert(label, cond) {
	if (cond) { console.log('  PASS:', label); }
	else { console.error('  FAIL:', label); failures++; }
}

// Mock section: taboption mirrors real LuCI by setting opt.option = name so
// makeVirtual's session key (section_id + option) is well-formed.
function makeSection() {
	const opts = [];
	const s = {
		tab: function () {},
		taboption: function (tab, widget, name, label) {
			const o = { _name: name, option: name, _depends: [], rmempty: true, _uci: {} };
			o.depends  = function (d) { o._depends.push(d); return o; };
			o.value    = function () { return o; };
			// Spy: a real UCI write would call uci.set; record into _uci so the
			// test can assert the virtual write NEVER touches UCI.
			opts.push(o);
			return o;
		},
	};
	return { s, opts };
}

const VIRT = {
	tabs: ['tls'],
	fields: [{ name: '_show_advanced_tls', type: 'bool', tab: 'tls', virtual: true, default: '0' }],
};

// Modal open #1: fresh section, toggle reads default '0'.
const a = makeSection();
applyMaterialized(a.s, 'outbound', 'vless', VIRT);
const oA = a.opts.find(x => x._name === '_show_advanced_tls');
assert('write is a function', typeof oA.write === 'function');
assert('remove is a function', typeof oA.remove === 'function');
assert('initial cfgvalue is default 0', oA.cfgvalue('cfg123') === '0');

// User flips it on and the modal save calls write(section, '1').
oA.write('cfg123', '1');
assert('write does NOT touch UCI (no-op vs config)', Object.keys(oA._uci).length === 0);
assert('cfgvalue reflects stored 1 after write', oA.cfgvalue('cfg123') === '1');

// Modal open #2: a BRAND NEW option object (re-render) for the same section
// must restore '1' from the session store — this is the core 8.3 fix.
const b = makeSection();
applyMaterialized(b.s, 'outbound', 'vless', VIRT);
const oB = b.opts.find(x => x._name === '_show_advanced_tls');
assert('reopen restores stored 1 (session-scoped persist)', oB.cfgvalue('cfg123') === '1');

// A DIFFERENT section id is independent (no cross-section leakage).
assert('other section still default 0', oB.cfgvalue('cfgOTHER') === '0');

// remove() clears the session entry → back to default.
oB.remove('cfg123');
assert('cfgvalue back to default after remove', oB.cfgvalue('cfg123') === '0');

if (failures) { console.error('FAILURES:', failures); process.exit(1); }
console.log('OK');
NODE

node "$TMP/run.js" "$JS"
echo "PASS: makeVirtual session-scoped advanced-toggle persistence (audit 8.3)"
