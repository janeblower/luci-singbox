#!/bin/sh
# tests/test_descriptor_form_dynamic_js.sh — node-based unit tests for the
# dynamic-source selector support in lib/descriptor_form.js::applyMaterialized().
#
# A descriptor field carrying `dynamic: "<source>"` is rendered as a selector
# whose options are populated at .load() time from live UCI / network state
# instead of a static `values` array:
#   * dynamic:"outbounds"   → single ListValue of singbox-ui `outbound` tags
#   * dynamic:"dns_servers" → single ListValue of singbox-ui `dns_server` tags
#   * dynamic:"interfaces"  → single ListValue of network logical interfaces
#   * dynamic:"devices"     → multi DynamicList seeded with netdev suggestions
#                             (free entry retained — device names like eth0.100
#                              are not all enumerable)
# String/list fields carrying a static `values` array render as a combobox
# (free entry + datalist suggestions), NOT a strict dropdown.
#
# Skips when node is unavailable, mirroring tests/test_descriptor_form_js.sh.
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

// LuCI widget shims as constructors carrying a prototype.load — the dynamic
// loaders call `form.<Widget>.prototype.load.apply(this, arguments)` after
// populating choices, mirroring tabs/*.js loadOutboundList().
function mkWidget(tag) {
	function W() {}
	W._tag = tag;
	W.prototype.load = function () { this._baseLoaded = true; return 'base:' + tag; };
	return W;
}
const form = {
	Flag:        mkWidget('Flag'),
	ListValue:   mkWidget('ListValue'),
	DynamicList: mkWidget('DynamicList'),
	MultiValue:  mkWidget('MultiValue'),
	Value:       mkWidget('Value'),
};

const validators = { host: () => true, port: () => true, uuid: () => true };

// Live-state shims.
const uci = {
	sections: function (config, type) {
		if (config === 'singbox-ui' && type === 'outbound')
			return [{ '.name': 'proxy_a' }, { '.name': 'proxy_b' }];
		if (config === 'singbox-ui' && type === 'dns_server')
			return [{ '.name': 'cloudflare', type: 'https' }];
		if (config === 'network' && type === 'interface')
			return [{ '.name': 'loopback' }, { '.name': 'lan' }, { '.name': 'wan' }];
		if (config === 'singbox-ui' && type === 'ruleset')
			return [{ '.name': 'rs_geoip', type: 'remote' }, { '.name': 'rs_ads', type: 'local' }];
		if (config === 'singbox-ui' && type === 'route_rule')
			return [
				{ '.name': 'rule_default', type: 'default' },
				{ '.name': 'rule_logical', type: 'logical' },
			];
		if (config === 'singbox-ui' && type === 'inbound')
			return [
				{ '.name': 'tp1', enabled: '1', protocol: 'tproxy', nft_rules: '1' },
				{ '.name': 'tp2', enabled: '1', protocol: 'tproxy' },
			];
		return [];
	},
	get: function (config, sid, opt) {
		var rows = uci.sections('singbox-ui', 'inbound');
		var row = rows.filter(function (r) { return r['.name'] === sid; })[0];
		return row ? row[opt] : undefined;
	},
	_setCalls: [],
	set: function (config, sid, opt, val) { uci._setCalls.push([sid, opt, val]); },
};

// SbViewState + SbCommon shims (require lines are stripped by the harness regex;
// these inject the real APIs into the sandbox so the version-gate code works).
const SbViewState = {
	_ver: '',
	getCoreVersion: function () { return SbViewState._ver; },
	setCoreVersion: function (v) { SbViewState._ver = v || ''; },
};
const SbCommon = {
	compareVersions: function (a, b) {
		const pa = String(a).split('.').map(Number);
		const pb = String(b).split('.').map(Number);
		const len = Math.max(pa.length, pb.length);
		for (let i = 0; i < len; i++) {
			const na = pa[i] || 0, nb = pb[i] || 0;
			if (na !== nb) return na > nb ? 1 : -1;
		}
		return 0;
	},
};
const network = {
	getDevices: function () {
		return Promise.resolve([
			{ getName: () => 'br-lan' },
			{ getName: () => 'eth0' },
		]);
	},
};

const sandbox = {
	__moduleExports: null,
	_:           (s) => s,
	L:           { Class: { extend: (o) => o } },
	form:        form,
	ui:          {},
	validators:  validators,
	uci:         uci,
	network:     network,
	SbViewState: SbViewState,
	SbCommon:    SbCommon,
	console:     console,
	Promise:     Promise,
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
function pass(label) { console.log('  PASS:', label); }
function fail(label, msg) { console.error('  FAIL:', label, ' —', msg); failures++; }

function makeSection() {
	const opts = [];
	const s = {
		tab: function () {},
		taboption: function (tab, widget, name, label) {
			const o = {
				_tab: tab, _widget: widget, _name: name,
				_depends: [], _values: [], rmempty: true,
				keylist: [], vallist: [],
			};
			o.depends = function (d) { o._depends.push(d); return o; };
			o.value   = function (k, v) { o._values.push([k, v]); return o; };
			opts.push(o);
			return o;
		},
	};
	return { s, opts };
}

function findOpt(opts, name) { return opts.find(o => o._name === name); }
function keysOf(opt) { return opt._values.map(v => v[0]); }

// ---------------------------------------------------------------------------
// 1. dynamic:"outbounds" → ListValue, load() = (none) + outbound tags.
// ---------------------------------------------------------------------------
{
	const { s, opts } = makeSection();
	applyMaterialized(s, 'outbound', 'vless', {
		tabs: ['dial'],
		fields: [{ name: 'detour', type: 'string', tab: 'dial', dynamic: 'outbounds' }],
	});
	const o = findOpt(opts, 'detour');
	if (o && o._widget === form.ListValue) pass('detour: dynamic outbounds → ListValue widget');
	else fail('detour widget', 'got ' + (o && o._widget && o._widget._tag));

	if (o && typeof o.load === 'function') {
		o.load.call(o, 'sid');
		const k = keysOf(o);
		if (k.length === 3 && k[0] === '' && k.indexOf('proxy_a') >= 0 && k.indexOf('proxy_b') >= 0)
			pass('detour: load() populates (none) + outbound tags');
		else fail('detour load values', JSON.stringify(o._values));
	} else fail('detour load', 'no load function attached');
}

// ---------------------------------------------------------------------------
// 1b. dynamic:"outbounds" + type:"list" → DynamicList (free-entry multi-select).
//     load() populates outbound suggestions (excluding own section_id), free entry ok.
// ---------------------------------------------------------------------------
{
	const { s, opts } = makeSection();
	applyMaterialized(s, 'outbound', 'selector', {
		tabs: ['basic'],
		fields: [{ name: 'outbounds', type: 'list', tab: 'basic', dynamic: 'outbounds' }],
	});
	const o = findOpt(opts, 'outbounds');
	if (o && o._widget === form.DynamicList) pass('outbounds list: dynamic outbounds + type list → DynamicList widget');
	else fail('outbounds list widget', 'got ' + (o && o._widget && o._widget._tag));

	if (o && typeof o.load === 'function') {
		o.load.call(o, 'proxy_a');
		const k = keysOf(o);
		// section_id 'proxy_a' is excluded; 'proxy_b' must appear; no (none) sentinel
		if (k.indexOf('proxy_b') >= 0 && k.indexOf('proxy_a') < 0)
			pass('outbounds list: load() suggests tags, excludes own section_id');
		else fail('outbounds list load values', JSON.stringify(o._values));
	} else fail('outbounds list load', 'no load function attached');
}

// ---------------------------------------------------------------------------
// 1c. dynamic:"outbounds" + type:"string" → ListValue (single-select, unchanged).
// ---------------------------------------------------------------------------
{
	const { s, opts } = makeSection();
	applyMaterialized(s, 'outbound', 'vless', {
		tabs: ['dial'],
		fields: [{ name: 'detour2', type: 'string', tab: 'dial', dynamic: 'outbounds' }],
	});
	const o = findOpt(opts, 'detour2');
	if (o && o._widget === form.ListValue) pass('detour string: dynamic outbounds + type string → ListValue (single-select unchanged)');
	else fail('detour string widget', 'got ' + (o && o._widget && o._widget._tag));
}

// ---------------------------------------------------------------------------
// 2. dynamic:"interfaces" → ListValue, logical ifaces minus loopback.
// ---------------------------------------------------------------------------
{
	const { s, opts } = makeSection();
	applyMaterialized(s, 'outbound', 'vless', {
		tabs: ['dial'],
		fields: [{ name: 'bind_interface', type: 'string', tab: 'dial', dynamic: 'interfaces' }],
	});
	const o = findOpt(opts, 'bind_interface');
	if (o && o._widget === form.ListValue) pass('bind_interface: dynamic interfaces → ListValue');
	else fail('bind_interface widget', 'got ' + (o && o._widget && o._widget._tag));

	o.load.call(o, 'sid');
	const k = keysOf(o);
	if (k.indexOf('lan') >= 0 && k.indexOf('wan') >= 0 && k.indexOf('loopback') < 0)
		pass('bind_interface: load() lists logical ifaces, drops loopback');
	else fail('bind_interface load values', JSON.stringify(o._values));
}

// ---------------------------------------------------------------------------
// 3. dynamic:"devices" (type list) → DynamicList, async netdev suggestions,
//    free entry retained.
// ---------------------------------------------------------------------------
function test3() {
	const { s, opts } = makeSection();
	applyMaterialized(s, 'inbound', 'tproxy', {
		tabs: ['basic'],
		fields: [{ name: 'interface', type: 'list', tab: 'basic', dynamic: 'devices' }],
	});
	const o = findOpt(opts, 'interface');
	if (o && o._widget === form.DynamicList) pass('interface: dynamic devices → DynamicList widget');
	else fail('interface widget', 'got ' + (o && o._widget && o._widget._tag));

	const r = o.load.call(o, 'sid');
	if (r && typeof r.then === 'function') {
		return r.then(function () {
			const k = keysOf(o);
			if (k.indexOf('br-lan') >= 0 && k.indexOf('eth0') >= 0)
				pass('interface: load() resolves netdev suggestions');
			else fail('interface load values', JSON.stringify(o._values));
		});
	}
	fail('interface load', 'expected a Promise from devices loader');
	return Promise.resolve();
}

// ---------------------------------------------------------------------------
// 4. string + static values → combobox (form.Value), suggestions populated,
//    free entry preserved (NOT a strict ListValue).
// ---------------------------------------------------------------------------
{
	const { s, opts } = makeSection();
	applyMaterialized(s, 'outbound', 'shadowsocks', {
		tabs: ['basic'],
		fields: [{ name: 'plugin', type: 'string', tab: 'basic',
		           values: ['obfs-local', 'v2ray-plugin', 'shadow-tls'] }],
	});
	const o = findOpt(opts, 'plugin');
	if (o && o._widget === form.Value) pass('plugin: string+values → Value (combobox, free entry)');
	else fail('plugin widget', 'got ' + (o && o._widget && o._widget._tag));
	const k = keysOf(o);
	if (k.length === 3 && k.indexOf('obfs-local') >= 0 && k.indexOf('shadow-tls') >= 0)
		pass('plugin: static value suggestions populated');
	else fail('plugin suggestions', JSON.stringify(o._values));
}

// ---------------------------------------------------------------------------
// 5. list + static values → DynamicList combobox suggestions (ALPN).
// ---------------------------------------------------------------------------
{
	const { s, opts } = makeSection();
	applyMaterialized(s, 'outbound', 'vless', {
		tabs: ['tls'],
		fields: [{ name: 'tls_alpn', type: 'list', tab: 'tls',
		           values: ['h2', 'http/1.1', 'h3'] }],
	});
	const o = findOpt(opts, 'tls_alpn');
	if (o && o._widget === form.DynamicList) pass('tls_alpn: list+values → DynamicList');
	else fail('tls_alpn widget', 'got ' + (o && o._widget && o._widget._tag));
	const k = keysOf(o);
	if (k.indexOf('h2') >= 0 && k.indexOf('http/1.1') >= 0 && k.indexOf('h3') >= 0)
		pass('tls_alpn: suggestions populated');
	else fail('tls_alpn suggestions', JSON.stringify(o._values));
}

// ---------------------------------------------------------------------------
// 6. dynamic:"rulesets" + type:"list" → DynamicList (generic list branch).
//    load() populates ruleset suggestions with name+(type) labels.
// ---------------------------------------------------------------------------
{
	const { s, opts } = makeSection();
	applyMaterialized(s, 'route_rule', 'default', {
		tabs: ['match'],
		fields: [{ name: 'rule_set', type: 'list', tab: 'match', dynamic: 'rulesets' }],
	});
	const o = findOpt(opts, 'rule_set');
	if (o && o._widget === form.DynamicList) pass('rulesets list: dynamic rulesets + type list → DynamicList widget');
	else fail('rulesets list widget', 'got ' + (o && o._widget && o._widget._tag));

	if (o && typeof o.load === 'function') {
		o.load.call(o, 'sid');
		const k = keysOf(o);
		if (k.indexOf('rs_geoip') >= 0 && k.indexOf('rs_ads') >= 0)
			pass('rulesets list: load() populates ruleset suggestions');
		else fail('rulesets list load values', JSON.stringify(o._values));
	} else fail('rulesets list load', 'no load function attached');
}

// ---------------------------------------------------------------------------
// 7. per-field min_version gate: field with min_version > core is skipped;
//    field with min_version <= core (or unknown core) is rendered.
// ---------------------------------------------------------------------------
{
	// 7a. core unknown → fail-open, both fields rendered.
	SbViewState._ver = '';
	const { s: s7a, opts: opts7a } = makeSection();
	applyMaterialized(s7a, 'outbound', 'vless', {
		tabs: ['basic'],
		fields: [
			{ name: 'new_field', type: 'string', tab: 'basic', min_version: '99.0.0' },
			{ name: 'old_field', type: 'string', tab: 'basic' },
		],
	});
	const nf7a = findOpt(opts7a, 'new_field');
	const of7a = findOpt(opts7a, 'old_field');
	if (nf7a) pass('min_version gate: core unknown → fail-open (new_field rendered)');
	else fail('min_version gate fail-open', 'new_field was skipped despite unknown core');
	if (of7a) pass('min_version gate: old_field without min_version always rendered');
	else fail('min_version gate old_field', 'old_field missing');

	// 7b. core 1.12.0, field requires 1.14.0 → field skipped.
	SbViewState._ver = '1.12.0';
	const { s: s7b, opts: opts7b } = makeSection();
	applyMaterialized(s7b, 'outbound', 'vless', {
		tabs: ['basic'],
		fields: [
			{ name: 'future_field', type: 'string', tab: 'basic', min_version: '1.14.0' },
			{ name: 'compat_field', type: 'string', tab: 'basic', min_version: '1.12.0' },
		],
	});
	const ff7b = findOpt(opts7b, 'future_field');
	const cf7b = findOpt(opts7b, 'compat_field');
	if (!ff7b) pass('min_version gate: 1.12 core, min_version 1.14 → field skipped');
	else fail('min_version gate skip', 'future_field should be skipped on 1.12 core');
	if (cf7b) pass('min_version gate: 1.12 core, min_version 1.12 → field rendered');
	else fail('min_version gate compat', 'compat_field with matching version should render');
}

// ---------------------------------------------------------------------------
// 8. exclusive bool flag: second tproxy section is gated off; only the first
//    owner may persist "1".
// ---------------------------------------------------------------------------
{
	const { s, opts } = makeSection();
	applyMaterialized(s, 'inbound', 'tproxy', {
		tabs: ['basic'],
		fields: [{ name: 'nft_rules', type: 'bool', tab: 'basic', exclusive: true }],
	});
	const o = findOpt(opts, 'nft_rules');
	if (o && typeof o._exclusiveOwner === 'function') pass('exclusive: owner helper attached');
	else fail('exclusive owner helper', 'missing _exclusiveOwner');

	if (o && o._exclusiveOwner('tp2') === 'tp1') pass('exclusive: tp1 owns nft rules');
	else fail('exclusive owner', 'expected tp1, got ' + (o && o._exclusiveOwner && o._exclusiveOwner('tp2')));

	uci._setCalls = [];
	o.write('tp2', '1');
	const w2 = uci._setCalls.filter(function (c) { return c[0] === 'tp2'; })[0];
	if (w2 && w2[2] === '0') pass('exclusive: non-owner write forced to 0');
	else fail('exclusive non-owner write', JSON.stringify(uci._setCalls));

	uci._setCalls = [];
	o.write('tp1', '1');
	const w1 = uci._setCalls.filter(function (c) { return c[0] === 'tp1'; })[0];
	if (w1 && w1[2] === '1') pass('exclusive: owner write keeps 1');
	else fail('exclusive owner write', JSON.stringify(uci._setCalls));
}

test3().then(function () {
	if (failures) {
		console.error('test_descriptor_form_dynamic_js: ' + failures + ' failure(s)');
		process.exit(1);
	}
	console.log('OK');
});
NODE

node "$TMP/run.js" "$JS"
echo "PASS: descriptor_form dynamic-selector unit tests"
