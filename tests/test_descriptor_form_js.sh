#!/bin/sh
# tests/test_descriptor_form_js.sh — node-based unit tests for
# lib/descriptor_form.js::applyMaterialized() (the live renderer; the legacy
# applyDescriptor was removed once inbounds.js/outbounds.js fully migrated).
# Mocks LuCI's `form`, `ui`, `validators`, and `L` globals via
# vm.createContext, then asserts tab registration, taboption call count,
# object-chain depends arms, widget mapping, password, rmempty, enum values,
# cross-protocol dedup + enum union, advanced/parent_enabled/virtual wiring,
# and the inbound-vs-outbound discriminator.
# Skips when node is unavailable, mirroring tests/test_validators_js.sh.
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

// Strip the LuCI fragment header (use strict + require dsl) and rewrite the
// trailing `return L.Class.extend({...});` into an assignment so we can
// pull the exported namespace out of the sandbox.
const body = src
	.replace(/^'use strict';\s*/, '')
	.replace(/^'require [^']+';\s*/gm, '')
	.replace(/return L\.Class\.extend\((\{[\s\S]*\})\);?\s*$/, '__moduleExports = $1;');

// LuCI form widget shims — plain sentinel strings so identity checks work.
const form = {
	Flag:        'Flag',
	ListValue:   'ListValue',
	DynamicList: 'DynamicList',
	Value:       'Value',
};

// validators shim — all return true (we only care they are functions).
const validators = {
	host:  () => true,
	port:  () => true,
	uuid:  () => true,
	alpn:  () => true,
};

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
if (!DF || typeof DF.applyMaterialized !== 'function') {
	console.error('FAIL: descriptor_form.js did not export applyMaterialized');
	process.exit(1);
}
const applyMaterialized = DF.applyMaterialized;

let failures = 0;
function pass(label) { console.log('  PASS:', label); }
function fail(label, msg) {
	console.error('  FAIL:', label, ' —', msg);
	failures++;
}

// ---------------------------------------------------------------------------
// Helper: mock section recording tab()/taboption() calls. depends() now takes
// a single object (the materialized renderer builds object-chain arms), not
// the legacy (key,value) pair.
// ---------------------------------------------------------------------------
function makeSection() {
	const opts = [];
	const tabs = [];
	const s = {
		tab: function(name, title) { tabs.push([name, title]); },
		taboption: function(tab, widget, name, label) {
			const o = {
				_tab:     tab,
				_widget:  widget,
				_name:    name,
				_label:   label,
				_depends: [],
				_values:  [],
				rmempty:  true,
			};
			o.depends = function(d) { o._depends.push(d); return o; };
			o.value   = function(k, v) { o._values.push([k, v]); return o; };
			opts.push(o);
			return o;
		},
	};
	return { s, opts, tabs };
}

// ---------------------------------------------------------------------------
// Sample materialized outbound payload — covers all widget types.
// ---------------------------------------------------------------------------
const mat = {
	sing_box_type: 'vless',
	tabs: ['basic', 'tls'],
	fields: [
		{ name: 'server',      type: 'string', tab: 'basic', required: true, validate: 'host' },
		{ name: 'server_port', type: 'string', tab: 'basic', required: true, validate: 'port' },
		{ name: 'server_uuid', type: 'string', tab: 'basic', secret: true,   validate: 'uuid' },
		{ name: 'vless_flow',  type: 'enum',   tab: 'tls',   values: ['', 'xtls-rprx-vision'] },
		{ name: 'multi',       type: 'list',   tab: 'tls' },
		{ name: 'enabled',     type: 'bool',   tab: 'tls' },
	],
};

const { s, opts, tabs } = makeSection();
applyMaterialized(s, 'outbound', 'vless', mat);

// 1. Call count matches field count.
if (opts.length === mat.fields.length) {
	pass('taboption call count (' + opts.length + ')');
} else {
	fail('taboption call count',
		'expected ' + mat.fields.length + ', got ' + opts.length);
}

// 2. Each declared tab is registered exactly once.
if (tabs.length === 2 &&
    tabs.some(t => t[0] === 'basic') &&
    tabs.some(t => t[0] === 'tls')) {
	pass('tabs registered once (basic, tls)');
} else {
	fail('tabs registered once', JSON.stringify(tabs));
}

// 3. Each option has exactly one depends arm {type:'vless'} (no extra keys).
let depOk = true;
for (const o of opts) {
	if (o._depends.length !== 1) {
		fail("depends count for '" + o._name + "'",
			'expected 1, got ' + o._depends.length);
		depOk = false;
	} else {
		const d = o._depends[0];
		const keys = Object.keys(d);
		if (keys.length !== 1 || d.type !== 'vless') {
			fail("depends arm for '" + o._name + "'",
				'expected {type:vless}, got ' + JSON.stringify(d));
			depOk = false;
		}
	}
}
if (depOk) pass("depends({type:'vless'}) on every outbound option");

// 4. Widget mapping.
const widgetMap = {
	server:      'Value',
	server_port: 'Value',
	server_uuid: 'Value',
	vless_flow:  'ListValue',
	multi:       'DynamicList',
	enabled:     'Flag',
};
let widgetOk = true;
for (const o of opts) {
	if (o._widget !== widgetMap[o._name]) {
		fail("widget for '" + o._name + "'",
			'expected ' + widgetMap[o._name] + ', got ' + o._widget);
		widgetOk = false;
	}
}
if (widgetOk) pass('widget mapping (string → Value, list → DynamicList, bool → Flag, enum → ListValue)');

// 5. secret:true → password=true.
const uuidOpt = opts.find(o => o._name === 'server_uuid');
if (uuidOpt && uuidOpt.password === true) {
	pass('secret:true → password=true');
} else {
	fail('secret:true → password=true',
		'server_uuid.password = ' + (uuidOpt && uuidOpt.password));
}

// 6. required:true → rmempty=false.
const serverOpt = opts.find(o => o._name === 'server');
if (serverOpt && serverOpt.rmempty === false) {
	pass('required:true → rmempty=false');
} else {
	fail('required:true → rmempty=false',
		'server.rmempty = ' + (serverOpt && serverOpt.rmempty));
}

// 7. Enum values populated (vless_flow has 2 entries: '' and 'xtls-rprx-vision').
const flowOpt = opts.find(o => o._name === 'vless_flow');
if (flowOpt && flowOpt._values.length === 2) {
	pass('enum values populated (2 entries for vless_flow)');
} else {
	fail('enum values populated',
		'vless_flow._values.length = ' + (flowOpt && flowOpt._values.length));
}

// 8. Non-required, non-secret field keeps rmempty=true default + modalonly set.
const multiOpt = opts.find(o => o._name === 'multi');
if (multiOpt && multiOpt.rmempty === true && multiOpt.modalonly === true) {
	pass('optional field keeps rmempty=true and is modalonly');
} else {
	fail('optional field keeps rmempty=true and is modalonly',
		'multi.rmempty=' + (multiOpt && multiOpt.rmempty) + ' modalonly=' + (multiOpt && multiOpt.modalonly));
}

// ---------------------------------------------------------------------------
// Test 9: inbound discriminator uses 'protocol' not 'type'.
// ---------------------------------------------------------------------------
const { s: s2, opts: opts2 } = makeSection();
applyMaterialized(s2, 'inbound', 'trojan', {
	sing_box_type: 'trojan',
	tabs: ['basic'],
	fields: [
		{ name: 'listen_port', type: 'string', tab: 'basic' },
	],
});

if (opts2.length === 1 &&
    opts2[0]._depends.length === 1 &&
    Object.keys(opts2[0]._depends[0]).length === 1 &&
    opts2[0]._depends[0].protocol === 'trojan') {
	pass("inbound uses depends({protocol:...}) not depends({type:...})");
} else {
	fail("inbound discriminator",
		JSON.stringify(opts2[0] && opts2[0]._depends));
}

// ---------------------------------------------------------------------------
// Test 10: null/missing/fieldless payload does not throw.
// ---------------------------------------------------------------------------
let threw = false;
try {
	const { s: sNull } = makeSection();
	applyMaterialized(sNull, 'outbound', 'vless', null);
	applyMaterialized(sNull, 'outbound', 'vless', { sing_box_type: 'vless' });
} catch (e) {
	threw = true;
	fail('null/missing payload guard', e.message);
}
if (!threw) pass('null/missing payload handled without throw');

// ---------------------------------------------------------------------------
// Test 11: Dedup — shared (tab,name) across two protocols → one taboption,
// two depends arms (one per protocol).
// ---------------------------------------------------------------------------
{
	const { s: sDedup, opts: optsDedup } = makeSection();
	applyMaterialized(sDedup, 'outbound', 'protoA',
		{ tabs: ['basic'], fields: [{ name: 'shared', type: 'string', tab: 'basic' }] });
	applyMaterialized(sDedup, 'outbound', 'protoB',
		{ tabs: ['basic'], fields: [{ name: 'shared', type: 'string', tab: 'basic' }] });

	const sharedCalls = optsDedup.filter(o => o._name === 'shared');
	if (sharedCalls.length === 1) {
		pass('shared field deduped to one taboption');
	} else {
		fail('shared field deduped to one taboption',
			'expected 1, got ' + sharedCalls.length);
	}

	const opt = sharedCalls[0];
	if (opt && opt._depends.length === 2) {
		pass('shared has depends from both protocols');
	} else {
		fail('shared has depends from both protocols',
			'expected 2, got ' + (opt && opt._depends.length));
	}

	const dep0 = opt && opt._depends[0];
	if (dep0 && dep0.type === 'protoA') {
		pass('first depends arm is protoA');
	} else {
		fail('first depends arm is protoA', JSON.stringify(dep0));
	}

	const dep1 = opt && opt._depends[1];
	if (dep1 && dep1.type === 'protoB') {
		pass('second depends arm is protoB');
	} else {
		fail('second depends arm is protoB', JSON.stringify(dep1));
	}

	if (opt && opt.modalonly === true) {
		pass('materialized fields default to modalonly');
	} else {
		fail('materialized fields default to modalonly',
			'shared.modalonly = ' + (opt && opt.modalonly));
	}
}

// ---------------------------------------------------------------------------
// Test 12: Enum-merge overlap — two protocols declare same field with
// different enum values; merged option carries the union, no duplicates.
// ---------------------------------------------------------------------------
{
	const { s: sEnumMerge, opts: optsEnumMerge } = makeSection();
	applyMaterialized(sEnumMerge, 'outbound', 'protoA',
		{ tabs: ['basic'], fields: [{ name: 'mode', type: 'enum', tab: 'basic', values: ['', 'x', 'y'] }] });
	applyMaterialized(sEnumMerge, 'outbound', 'protoB',
		{ tabs: ['basic'], fields: [{ name: 'mode', type: 'enum', tab: 'basic', values: ['y', 'z'] }] });

	const modeCalls = optsEnumMerge.filter(o => o._name === 'mode');
	if (modeCalls.length === 1) {
		pass('enum field deduped to one taboption');
	} else {
		fail('enum field deduped to one taboption',
			'expected 1, got ' + modeCalls.length);
	}

	const modeOpt = modeCalls[0];

	if (modeOpt && modeOpt._depends.length === 2) {
		pass('enum mode has depends from both protocols');
	} else {
		fail('enum mode has depends from both protocols',
			'expected 2, got ' + (modeOpt && modeOpt._depends.length));
	}

	const valueKeys = modeOpt && modeOpt._values.map(v => v[0]);
	const expectedKeys = ['', 'x', 'y', 'z'];
	let valuesMatch = !!valueKeys && valueKeys.length === expectedKeys.length;
	if (valuesMatch) {
		for (let i = 0; i < expectedKeys.length; i++) {
			if (valueKeys[i] !== expectedKeys[i]) { valuesMatch = false; break; }
		}
	}
	if (valuesMatch) {
		pass('enum merge: values are [, x, y, z] (union, no duplicates)');
	} else {
		fail('enum merge: values are [, x, y, z]',
			'got ' + JSON.stringify(valueKeys));
	}
}

// ---------------------------------------------------------------------------
// Test 13: advanced + parent_enabled + depends → a single depends arm that
// ANDs the protocol gate with the per-value depends, the parent_enabled flag,
// and the per-tab _show_advanced toggle. Uses kind 'dns' because the advanced
// toggle is now scoped to dns/route only (Bug 4); inbound/outbound skip it
// (covered by Test 13b below).
// ---------------------------------------------------------------------------
{
	const { s: sAdv, opts: optsAdv } = makeSection();
	applyMaterialized(sAdv, 'dns', 'vless', {
		tabs: ['tls'],
		fields: [{
			name: 'reality_short_id', type: 'string', tab: 'tls',
			advanced: true, parent_enabled: 'tls_enable',
			depends: { field: 'tls_reality', value: '1' },
		}],
	});
	const o = optsAdv.find(x => x._name === 'reality_short_id');
	const d = o && o._depends[0];
	if (d &&
	    d.type === 'vless' &&
	    d.tls_reality === '1' &&
	    d.tls_enable === '1' &&
	    d._show_advanced_tls === '1' &&
	    o._depends.length === 1) {
		pass('advanced/parent_enabled/depends folded into one AND-arm (dns)');
	} else {
		fail('advanced/parent_enabled/depends arm', JSON.stringify(o && o._depends));
	}
}

// ---------------------------------------------------------------------------
// Test 13b: for inbound/outbound the advanced toggle is NOT added to the arm
// (Bug 4 — all fields shown). parent_enabled + depends still apply.
// ---------------------------------------------------------------------------
{
	const { s: sNoAdv, opts: optsNoAdv } = makeSection();
	applyMaterialized(sNoAdv, 'outbound', 'vless', {
		tabs: ['tls'],
		fields: [{
			name: 'reality_short_id', type: 'string', tab: 'tls',
			advanced: true, parent_enabled: 'tls_enable',
			depends: { field: 'tls_reality', value: '1' },
		}],
	});
	const o = optsNoAdv.find(x => x._name === 'reality_short_id');
	const d = o && o._depends[0];
	if (d &&
	    d.type === 'vless' &&
	    d.tls_reality === '1' &&
	    d.tls_enable === '1' &&
	    !('_show_advanced_tls' in d) &&
	    o._depends.length === 1) {
		pass('outbound advanced field has no _show_advanced gate (Bug 4)');
	} else {
		fail('outbound advanced arm should omit _show_advanced_tls', JSON.stringify(o && o._depends));
	}
}

// ---------------------------------------------------------------------------
// Test 14: virtual field is write-suppressed and returns its default cfgvalue.
// ---------------------------------------------------------------------------
{
	const { s: sVirt, opts: optsVirt } = makeSection();
	applyMaterialized(sVirt, 'outbound', 'vless', {
		tabs: ['tls'],
		fields: [{ name: '_show_advanced_tls', type: 'bool', tab: 'tls', virtual: true, default: '0' }],
	});
	const o = optsVirt.find(x => x._name === '_show_advanced_tls');
	if (o && typeof o.write === 'function' && typeof o.remove === 'function' && o.cfgvalue() === '0') {
		pass('virtual field: write/remove suppressed, cfgvalue returns default');
	} else {
		fail('virtual field handling',
			'write=' + (o && typeof o.write) + ' cfgvalue=' + (o && o.cfgvalue && o.cfgvalue()));
	}
}

// ---------------------------------------------------------------------------
// Done.
// ---------------------------------------------------------------------------
if (failures) {
	console.error('test_descriptor_form_js: ' + failures + ' failure(s)');
	process.exit(1);
}
console.log('OK');
NODE

node "$TMP/run.js" "$JS"
echo "PASS: descriptor_form applyMaterialized unit tests"
