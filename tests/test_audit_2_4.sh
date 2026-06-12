#!/bin/sh
# tests/test_audit_2_4.sh — regression for audit 2.4.
# Shared (tab,name) fields collapse to ONE LuCI widget, which can only carry one
# title. Previously the FIRST-registered protocol's label always won, so
# reordering SB_*_PROTOCOLS could silently drop a curated per-field ui_label.
# applyMaterialized now resolves the label order-independently: an explicit
# ui_label beats a name-derived one regardless of registration order. This test
# registers the same field name from two protocols in BOTH orders and asserts
# the explicit ui_label wins either way.
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

const applyMaterialized = ctx.__moduleExports && ctx.__moduleExports.applyMaterialized;
if (typeof applyMaterialized !== 'function') {
	console.error('FAIL: no applyMaterialized export');
	process.exit(1);
}

let failures = 0;
function assert(label, cond) {
	if (cond) { console.log('  PASS:', label); }
	else { console.error('  FAIL:', label); failures++; }
}

// taboption records title and allows it to be reassigned (real LuCI stores the
// label as opt.title; applyMaterialized upgrades it via registered.opt.title).
function makeSection() {
	const opts = [];
	const s = {
		tab: function () {},
		taboption: function (tab, widget, name, title) {
			const o = { _name: name, title: title, option: name };
			o.depends = function () { return o; };
			o.value   = function () { return o; };
			opts.push(o);
			return o;
		},
	};
	return { s, opts };
}

// Two protocols declaring the SAME (basic, server_password) field. One uses a
// name-derived label (no ui_label); the other curates an explicit one.
const derived  = { tabs: ['basic'], fields: [{ name: 'server_password', type: 'string', tab: 'basic' }] };
const explicit = { tabs: ['basic'], fields: [{ name: 'server_password', type: 'string', tab: 'basic', ui_label: 'Password (single user)' }] };

// Order A: derived first, explicit second → explicit must still win.
{
	const { s, opts } = makeSection();
	applyMaterialized(s, 'inbound', 'shadowsocks', derived);
	applyMaterialized(s, 'inbound', 'hysteria2',   explicit);
	const o = opts.find(x => x._name === 'server_password');
	assert('single deduped widget (derived→explicit)', opts.filter(x => x._name === 'server_password').length === 1);
	assert('explicit ui_label wins when registered second', o.title === 'Password (single user)');
}

// Order B: explicit first, derived second → explicit (the first) stays, the
// derived label must NOT clobber it.
{
	const { s, opts } = makeSection();
	applyMaterialized(s, 'inbound', 'hysteria2',   explicit);
	applyMaterialized(s, 'inbound', 'shadowsocks', derived);
	const o = opts.find(x => x._name === 'server_password');
	assert('explicit ui_label kept when registered first', o.title === 'Password (single user)');
}

// Both derived (no explicit anywhere) → first-registered derived label, stable.
{
	const { s, opts } = makeSection();
	applyMaterialized(s, 'inbound', 'shadowsocks', derived);
	applyMaterialized(s, 'inbound', 'trojan',      derived);
	const o = opts.find(x => x._name === 'server_password');
	assert('derived label is the name-cased fallback', o.title === 'Server password');
}

if (failures) { console.error('FAILURES:', failures); process.exit(1); }
console.log('OK');
NODE

node "$TMP/run.js" "$JS"
echo "PASS: shared-field label resolution is order-independent (audit 2.4)"
