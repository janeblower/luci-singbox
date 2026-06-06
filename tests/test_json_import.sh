#!/bin/sh
# tests/test_json_import.sh — drives the JSON-import parser in main.js
# through node. Skips when node is unavailable.
set -e

if ! command -v node >/dev/null 2>&1; then
	echo "SKIP: node not available" >&2
	exit 0
fi

JS=luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/main.js
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Wrap the LuCI view fragment so we can extract the parser. Strip the
# 'require' DSL header, evaluate the body in a sandbox that stubs LuCI
# globals, and capture the named global parser.
cat >"$TMP/run.js" <<'NODE'
const fs = require('fs');
const vm = require('vm');
const path = require('path');
const src = fs.readFileSync(process.argv[2], 'utf8');

// Strip the LuCI fragment 'use strict' + requires + the view.extend wrapper.
const body = src
	.replace(/^'use strict';\s*/, '')
	.replace(/^'require [^']+';\s*/gm, '')
	.replace(/return view\.extend\(\{[\s\S]*\}\);?\s*$/, '');

const sandbox = {
	form: { Map: function(){}, GridSection: function(){}, NamedSection: function(){},
	        Value: function(){}, Flag: function(){}, ListValue: function(){},
	        DynamicList: function(){}, TextValue: function(){} },
	uci: { get: () => null, set: () => null, add: () => null, sections: () => [] },
	ui: { showModal: () => null, hideModal: () => null, createHandlerFn: () => (() => {}) },
	rpc: { declare: () => (() => Promise.resolve()) },
	widgets: { DeviceSelect: function(){} },
	view: { extend: (o) => o },
	_: (s) => s,
	E: () => ({ appendChild: () => null }),
	Promise: Promise,
	console: console,
	setTimeout: setTimeout,
};
// window must alias the sandbox so that `window.foo = bar` lands on the ctx.
sandbox.window = sandbox;

// Helper: evaluate a LuCI module file and return its exported object.
// Strips 'use strict' + 'require ...' lines, replaces `return L.Class.extend({...})`
// with an assignment so we can capture the exports.
function loadModule(filePath) {
	const msrc = fs.readFileSync(filePath, 'utf8');
	const mbody = msrc
		.replace(/^'use strict';\s*/, '')
		.replace(/^'require [^']+';\s*/gm, '')
		.replace(/return L\.Class\.extend\((\{[\s\S]*\})\);?\s*$/, '__moduleExports = $1;');
	const mctx = vm.createContext(Object.assign({}, sandbox, { __moduleExports: null }));
	vm.runInContext('(function() {' + mbody + '})();', mctx, { filename: path.basename(filePath) });
	return mctx.__moduleExports;
}

// Resolve module paths relative to main.js location.
const viewDir = path.dirname(process.argv[2]);

// Stub module variables that main.js references via var X = SbFoo.x aliases.
sandbox.SbRpc = {
	callRefresh: () => Promise.resolve(), callRestart: () => Promise.resolve(),
	callStatus: () => Promise.resolve(), callReadConfig: () => Promise.resolve(),
	callClash: () => Promise.resolve(), callDhcpLeases: () => Promise.resolve(),
};
sandbox.SbCommon = loadModule(path.join(viewDir, 'lib/common.js'));
sandbox.SbImpInbound  = loadModule(path.join(viewDir, 'importers/inbound.js'));
sandbox.SbImpOutbound = loadModule(path.join(viewDir, 'importers/outbound.js'));

const ctx = vm.createContext(sandbox);
vm.runInContext('(function() {' + body + '})();', ctx, { filename: 'main.js' });

const fn = ctx.SbImpInbound && ctx.SbImpInbound.jsonImportInbound;
if (typeof fn !== 'function') {
	console.error('FAIL: SbImpInbound.jsonImportInbound not defined');
	process.exit(1);
}

function expect(label, got, want) {
	const s1 = JSON.stringify(got), s2 = JSON.stringify(want);
	if (s1 !== s2) {
		console.error('FAIL', label, '\n  got ', s1, '\n  want', s2);
		process.exit(1);
	}
	console.log('ok', label);
}

expect('shadowsocks inbound',
	fn({ type: 'shadowsocks', tag: 'ss', listen: '::', listen_port: 8388,
	     method: 'aes-256-gcm', password: 'p' }),
	{ ok: true, errors: [], fields: {
		protocol: 'shadowsocks', listen: '::', listen_port: 8388,
		shadowsocks_method: 'aes-256-gcm', server_password: 'p',
	}});

expect('shadowsocks inbound multi-user',
	fn({ type: 'shadowsocks', tag: 'ss', listen: '::', listen_port: 8388,
	     method: '2022-blake3-aes-128-gcm',
	     users: [ { name: 'alice', password: 'pw1' },
	              { name: 'bob',   password: 'pw2' } ] }),
	{ ok: true, errors: [], fields: {
		protocol: 'shadowsocks', listen: '::', listen_port: 8388,
		shadowsocks_method: '2022-blake3-aes-128-gcm',
		ss_user: [ 'alice:pw1', 'bob:pw2' ],
	}});

expect('outbound JSON rejected',
	fn({ type: 'shadowsocks', server: 'a.b', server_port: 8388, password: 'p' }),
	{ ok: false,
	  errors: ['Looks like an outbound (has "server" without "listen"). Use the outbound importer.'],
	  fields: {} });

expect('unknown type rejected',
	fn({ type: 'wireguard' }),
	{ ok: false, errors: ['Unknown inbound type: wireguard'], fields: {} });

expect('missing type rejected',
	fn({ listen: '::', listen_port: 53 }),
	{ ok: false, errors: ['Missing "type" field'], fields: {} });

expect('vless with reality TLS',
	fn({ type: 'vless', listen: '::', listen_port: 443,
	     users: [{ uuid: 'u1', flow: 'xtls-rprx-vision' }],
	     tls: { enabled: true, server_name: 'cdn.example.com',
	            reality: { enabled: true, private_key: 'pk',
	                       short_id: ['ab12'],
	                       handshake: { server: 'www.example.com', server_port: 443 } } } }),
	{ ok: true, errors: [], fields: {
		protocol: 'vless', listen: '::', listen_port: 443,
		server_uuid: 'u1', vless_flow: 'xtls-rprx-vision',
		security: 'reality', tls_server_name: 'cdn.example.com',
		reality_private_key: 'pk', reality_short_id: 'ab12',
		reality_handshake_server: 'www.example.com',
		reality_handshake_server_port: '443',
	}});

const fnOut = ctx.SbImpOutbound && ctx.SbImpOutbound.jsonImportOutbound;
if (typeof fnOut !== 'function') {
	console.error('FAIL: SbImpOutbound.jsonImportOutbound not defined');
	process.exit(1);
}

expect('vless outbound',
	fnOut({ type: 'vless', server: 'a.b', server_port: 443, uuid: 'uu',
	        tls: { enabled: true, server_name: 'a.b' } }),
	{ ok: true, errors: [], fields: {
		type: 'vless', server: 'a.b', server_port: 443, server_uuid: 'uu',
		security: 'tls', tls_server_name: 'a.b',
	}});

expect('inbound rejected as outbound',
	fnOut({ type: 'shadowsocks', listen: '::', listen_port: 8388,
	        method: 'aes-256-gcm', password: 'p' }),
	{ ok: false,
	  errors: ['Looks like an inbound (has "listen"). Use the inbound importer.'],
	  fields: {} });

expect('outbound missing type rejected',
	fnOut({ server: 'a.b', server_port: 443 }),
	{ ok: false, errors: ['Missing "type" field'], fields: {} });

expect('outbound unknown type rejected',
	fnOut({ type: 'wireguard' }),
	{ ok: false, errors: ['Unknown outbound type: wireguard'], fields: {} });

expect('hysteria2 outbound with obfs',
	fnOut({ type: 'hysteria2', server: 'h.b', server_port: 8443,
	        password: 'pw', up_mbps: 100, down_mbps: 50,
	        obfs: { type: 'salamander', password: 'op' } }),
	{ ok: true, errors: [], fields: {
		type: 'hysteria2', server: 'h.b', server_port: 8443,
		server_password: 'pw', up_mbps: '100', down_mbps: '50',
		hysteria2_obfs_type: 'salamander', hysteria2_obfs_password: 'op',
	}});

// vmess alterId: camelCase is canonical per sing-box 1.12 docs; legacy
// snake_case alter_id is still accepted for paste-compat with older configs.
expect('vmess inbound alterId camelCase',
	fn({ type: 'vmess', listen: '::', listen_port: 8443,
	     users: [{ uuid: 'u1', alterId: 7 }] }),
	{ ok: true, errors: [], fields: {
		protocol: 'vmess', listen: '::', listen_port: 8443,
		server_uuid: 'u1', vmess_alter_id: '7',
	}});
expect('vmess inbound legacy alter_id still accepted',
	fn({ type: 'vmess', listen: '::', listen_port: 8443,
	     users: [{ uuid: 'u1', alter_id: 4 }] }),
	{ ok: true, errors: [], fields: {
		protocol: 'vmess', listen: '::', listen_port: 8443,
		server_uuid: 'u1', vmess_alter_id: '4',
	}});

// vmess/vless multi-user: when users[] has >1 entry, importer emits a
// `list inbound_user` and drops section-level server_uuid/vmess_alter_id.
expect('vmess inbound multi-user',
	fn({ type: 'vmess', listen: '::', listen_port: 8443,
	     users: [ { name: 'alice', uuid: 'uuid-a' },
	              { name: 'bob',   uuid: 'uuid-b', alterId: 5 } ] }),
	{ ok: true, errors: [], fields: {
		protocol: 'vmess', listen: '::', listen_port: 8443,
		inbound_user: [ 'alice:uuid-a', 'bob:uuid-b:5' ],
	}});
expect('vless inbound multi-user with per-user flow',
	fn({ type: 'vless', listen: '::', listen_port: 4443,
	     users: [ { name: 'alice', uuid: 'uuid-a', flow: 'xtls-rprx-vision' },
	              { name: 'bob',   uuid: 'uuid-b' } ] }),
	{ ok: true, errors: [], fields: {
		protocol: 'vless', listen: '::', listen_port: 4443,
		inbound_user: [ 'alice:uuid-a:xtls-rprx-vision', 'bob:uuid-b' ],
	}});

// Multi-host http transport must land in transport_hosts (list); ws/etc.
// keep transport_host scalar.
expect('http transport multi-host routes to transport_hosts list',
	fnOut({ type: 'vless', server: 'a.b', server_port: 443, uuid: 'u',
	        transport: { type: 'http', host: ['a.example', 'b.example'], path: '/api' } }),
	{ ok: true, errors: [], fields: {
		type: 'vless', server: 'a.b', server_port: 443, server_uuid: 'u',
		transport: 'http', transport_path: '/api',
		transport_hosts: ['a.example', 'b.example'],
	}});
expect('ws transport host stays scalar',
	fnOut({ type: 'vless', server: 'a.b', server_port: 443, uuid: 'u',
	        transport: { type: 'ws', host: 'cdn.example', path: '/ws' } }),
	{ ok: true, errors: [], fields: {
		type: 'vless', server: 'a.b', server_port: 443, server_uuid: 'u',
		transport: 'ws', transport_path: '/ws', transport_host: 'cdn.example',
	}});

// tls.alpn must stay an array (UI now uses DynamicList).
expect('outbound tls alpn stays array',
	fnOut({ type: 'vless', server: 'a.b', server_port: 443, uuid: 'u',
	        tls: { enabled: true, alpn: ['h2', 'http/1.1'] } }),
	{ ok: true, errors: [], fields: {
		type: 'vless', server: 'a.b', server_port: 443, server_uuid: 'u',
		security: 'tls', tls_alpn: ['h2', 'http/1.1'],
	}});

// Builders don't implement these — importer must reject now.
expect('inbound rejects mixed (builder lacks support)',
	fn({ type: 'mixed', listen: '::', listen_port: 8080 }),
	{ ok: false, errors: ['Unknown inbound type: mixed'], fields: {} });
expect('outbound rejects direct (use type=interface)',
	fnOut({ type: 'direct', server: 'x.y', server_port: 1 }),
	{ ok: false, errors: ['Unknown outbound type: direct'], fields: {} });

console.log('OK');
NODE

node "$TMP/run.js" "$JS"
