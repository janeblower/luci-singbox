#!/bin/sh
# tests/test_share_link_js.sh — exercises importers/outbound.shareLinkImport
# from Node so the JS-side share-link parsing has regression coverage.
set -eu
cd "$(dirname "$0")/.."

NODE_BIN="${NODE_BIN:-node}"
command -v "$NODE_BIN" >/dev/null 2>&1 || { echo "SKIP test_share_link_js (node missing)"; exit 0; }

JS_FILE=luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/importers/outbound.js

"$NODE_BIN" -e "
const fs = require('fs');
const src = fs.readFileSync('$JS_FILE', 'utf8');

// Strip LuCI module preamble + 'use strict'; require headers; wrap so we can
// extract shareLinkImport via a fake L.Class.extend that returns the object.
const stub = \`
let _;
const _gettext = s => s;
global._ = _gettext;
global.atob = s => Buffer.from(s, 'base64').toString('binary');
global.L = { Class: { extend: obj => obj } };
\` + src
    .replace(/^'use strict';\\n/m, '')
    .replace(/^'require [^']+';\\n/gm, '');

let mod;
try {
    mod = (new Function(stub + '\\nreturn module && module.exports || arguments[0];'))();
} catch (e) {
    // Some LuCI files end with \`return L.Class.extend({...})\` instead of module.exports.
    // Wrap so the trailing return becomes the function's return value.
    const wrapped = '(function(){\\n' + stub + '\\n})()';
    mod = eval(wrapped);
}

function assert(label, cond) {
    if (!cond) { console.error('FAIL: ' + label); process.exit(1); }
    console.log('PASS: ' + label);
}

// Test 1: vless URL.
let r = mod.shareLinkImport('vless://11111111-2222-3333-4444-555555555555@example.com:443?type=tcp#vlsrv');
assert('vless type', r.ok && r.fields.type === 'vless');
assert('vless server', r.fields.server === 'example.com');
assert('vless port', r.fields.server_port === 443);
assert('vless uuid', r.fields.server_uuid === '11111111-2222-3333-4444-555555555555');

// Test 2: hysteria2 with obfs — MUST set obfs_type / obfs_password (NOT hysteria2_obfs_*).
r = mod.shareLinkImport('hysteria2://pw@h.example:443?obfs=salamander&obfs-password=op#hy2');
assert('hy2 type', r.ok && r.fields.type === 'hysteria2');
assert('hy2 password', r.fields.server_password === 'pw');
assert('hy2 obfs_type key (not hysteria2_obfs_type)', r.fields.obfs_type === 'salamander');
assert('hy2 obfs_password key (not hysteria2_obfs_password)', r.fields.obfs_password === 'op');
assert('hy2 no legacy hysteria2_obfs_type', !('hysteria2_obfs_type' in r.fields));

// Test 3: SS base64 SIP002 fallback.
const b64 = Buffer.from('aes-256-gcm:secret', 'utf8').toString('base64');
r = mod.shareLinkImport('ss://' + b64 + '@ss.example:8388#ss');
assert('ss SIP002 method', r.fields.shadowsocks_method === 'aes-256-gcm');
assert('ss SIP002 password', r.fields.server_password === 'secret');

// Test 4: trojan.
r = mod.shareLinkImport('trojan://tjpw@trojan.example:443#tj');
assert('trojan type', r.fields.type === 'trojan' && r.fields.server_password === 'tjpw');

// Test 5: SS plain form (modern method:password).
r = mod.shareLinkImport('ss://aes-128-gcm:mypass@ss2.example:8388#ss2');
assert('ss plain method', r.fields.shadowsocks_method === 'aes-128-gcm');
assert('ss plain password', r.fields.server_password === 'mypass');

console.log('ALL PASS: test_share_link_js');
"
