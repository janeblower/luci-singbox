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
const ctx = vm.createContext(sandbox);
vm.runInContext('(function() {' + body + '})();', ctx, { filename: 'main.js' });

const fn = ctx.__sb_jsonImportInbound;
if (typeof fn !== 'function') {
	console.error('FAIL: __sb_jsonImportInbound not defined');
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

const fnOut = ctx.__sb_jsonImportOutbound;
if (typeof fnOut !== 'function') {
	console.error('FAIL: __sb_jsonImportOutbound not defined');
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

console.log('OK');
NODE

node "$TMP/run.js" "$JS"
