#!/bin/sh
# tests/test_descriptor_form_js.sh — node-based unit tests for
# lib/descriptor_form.js::applyDescriptor(). Mocks LuCI's `form`, `ui`,
# `validators`, and `L` globals via vm.createContext, then asserts taboption
# call count, depends keys, widget mapping, password, rmempty, enum values,
# and inbound vs outbound discriminator.
# Skips when node is unavailable, mirroring tests/test_validators_js.sh.
set -e

if ! command -v node >/dev/null 2>&1; then
	echo "SKIP: node not available" >&2
	exit 0
fi

JS=luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/lib/descriptor_form.js
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
if (!DF || typeof DF.applyDescriptor !== 'function') {
	console.error('FAIL: descriptor_form.js did not export applyDescriptor');
	process.exit(1);
}
const applyDescriptor = DF.applyDescriptor;

let failures = 0;
function pass(label) { console.log('  PASS:', label); }
function fail(label, msg) {
	console.error('  FAIL:', label, ' —', msg);
	failures++;
}

// ---------------------------------------------------------------------------
// Helper: build a mock section that records taboption() calls.
// ---------------------------------------------------------------------------
function makeSection() {
	const opts = [];
	const s = {
		taboption: function(group, widget, name, label) {
			const o = {
				_group:   group,
				_widget:  widget,
				_name:    name,
				_label:   label,
				_depends: [],
				_values:  [],
				rmempty:  true,
			};
			o.depends = function(k, v) { o._depends.push([k, v]); return o; };
			o.value   = function(k, v) { o._values.push([k, v]);   return o; };
			opts.push(o);
			return o;
		},
	};
	return { s, opts };
}

// ---------------------------------------------------------------------------
// Sample outbound descriptor — covers all widget types.
// ---------------------------------------------------------------------------
const descriptor = {
	sing_box_type: 'vless',
	fields: [
		{ name: 'server',      type: 'string', required: true, validate: 'host', group: 'basic'       },
		{ name: 'server_port', type: 'number', required: true, validate: 'port', group: 'basic'       },
		{ name: 'server_uuid', type: 'string', secret: true,   validate: 'uuid', group: 'credentials' },
		{ name: 'vless_flow',  type: 'enum',   values: ['', 'xtls-rprx-vision'],  group: 'credentials' },
		{ name: 'multi',       type: 'list',   item: 'string',                    group: 'advanced'    },
		{ name: 'enabled',     type: 'bool',                                       group: 'advanced'    },
	],
};

const { s, opts } = makeSection();
applyDescriptor(s, 'outbound', 'vless', descriptor);

// 1. Call count matches field count.
if (opts.length === descriptor.fields.length) {
	pass('taboption call count (' + opts.length + ')');
} else {
	fail('taboption call count',
		'expected ' + descriptor.fields.length + ', got ' + opts.length);
}

// 2. Each option has exactly one depends('type', 'vless').
let depOk = true;
for (const o of opts) {
	if (o._depends.length !== 1) {
		fail("depends count for '" + o._name + "'",
			'expected 1, got ' + o._depends.length);
		depOk = false;
	} else if (o._depends[0][0] !== 'type' || o._depends[0][1] !== 'vless') {
		fail("depends value for '" + o._name + "'",
			'expected [type,vless], got ' + JSON.stringify(o._depends[0]));
		depOk = false;
	}
}
if (depOk) pass("depends('type','vless') on every outbound option");

// 3. Widget mapping.
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
if (widgetOk) pass('widget mapping (string/number → Value, list → DynamicList, bool → Flag, enum → ListValue)');

// 4. secret:true → password=true.
const uuidOpt = opts.find(o => o._name === 'server_uuid');
if (uuidOpt && uuidOpt.password === true) {
	pass('secret:true → password=true');
} else {
	fail('secret:true → password=true',
		'server_uuid.password = ' + (uuidOpt && uuidOpt.password));
}

// 5. required:true → rmempty=false.
const serverOpt = opts.find(o => o._name === 'server');
if (serverOpt && serverOpt.rmempty === false) {
	pass('required:true → rmempty=false');
} else {
	fail('required:true → rmempty=false',
		'server.rmempty = ' + (serverOpt && serverOpt.rmempty));
}

// 6. Enum values populated (vless_flow has 2 entries: '' and 'xtls-rprx-vision').
const flowOpt = opts.find(o => o._name === 'vless_flow');
if (flowOpt && flowOpt._values.length === 2) {
	pass('enum values populated (2 entries for vless_flow)');
} else {
	fail('enum values populated',
		'vless_flow._values.length = ' + (flowOpt && flowOpt._values.length));
}

// 7. Non-required, non-secret field keeps rmempty=true default.
const multiOpt = opts.find(o => o._name === 'multi');
if (multiOpt && multiOpt.rmempty === true) {
	pass('optional field keeps rmempty=true');
} else {
	fail('optional field keeps rmempty=true',
		'multi.rmempty = ' + (multiOpt && multiOpt.rmempty));
}

// ---------------------------------------------------------------------------
// Test 8: inbound discriminator uses 'protocol' not 'type'.
// ---------------------------------------------------------------------------
const { s: s2, opts: opts2 } = makeSection();
applyDescriptor(s2, 'inbound', 'trojan', {
	sing_box_type: 'trojan',
	fields: [
		{ name: 'listen_port', type: 'number', group: 'basic' },
	],
});

if (opts2.length === 1 &&
    opts2[0]._depends.length === 1 &&
    opts2[0]._depends[0][0] === 'protocol' &&
    opts2[0]._depends[0][1] === 'trojan') {
	pass("inbound uses depends('protocol', ...) not depends('type', ...)");
} else {
	fail("inbound discriminator",
		JSON.stringify(opts2[0] && opts2[0]._depends));
}

// ---------------------------------------------------------------------------
// Test 9: null/missing descriptor does not throw.
// ---------------------------------------------------------------------------
let threw = false;
try {
	applyDescriptor(s, 'outbound', 'vless', null);
	applyDescriptor(s, 'outbound', 'vless', { sing_box_type: 'vless' });
} catch (e) {
	threw = true;
	fail('null/missing descriptor guard', e.message);
}
if (!threw) pass('null/missing descriptor handled without throw');

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
