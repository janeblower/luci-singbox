#!/bin/sh
# tests/test_audit_9_3.sh — regression for audit 9.3.
# The ss:// share-link regex lacked a query-string group, so SIP002 links that
# carry ?plugin=name;opts before the #tag failed to match at all and the
# importer returned "Cannot parse shadowsocks URL". This exercises
# importers/outbound.shareLinkImport from Node and asserts that:
#   - a SIP002 ?plugin= link parses (server/port/method/password preserved), and
#   - plugin / plugin_opts are decomposed using the SAME field names and the
#     same first-';' split as the backend parse_ss() in sharelink.uc.
set -eu
. "$(dirname "$0")/lib/sb_helpers.sh"
cd "$(dirname "$0")/.."

NODE_BIN="${NODE_BIN:-node}"
command -v "$NODE_BIN" >/dev/null 2>&1 || { echo "SKIP test_audit_9_3 (node missing)"; exit 0; }

JS_FILE=${SB_VIEW}/importers/outbound.js

"$NODE_BIN" -e "
const fs = require('fs');
const src = fs.readFileSync('$JS_FILE', 'utf8');

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
    const wrapped = '(function(){\\n' + stub + '\\n})()';
    mod = eval(wrapped);
}

function assert(label, cond) {
    if (!cond) { console.error('FAIL: ' + label); process.exit(1); }
    console.log('PASS: ' + label);
}

// 1: SIP002 with ?plugin=obfs-local;obfs=http;obfs-host=... before #tag.
// Core server/port/method/password must survive (previously the whole link
// was rejected), and plugin / plugin_opts must split on the FIRST ';'.
let r = mod.shareLinkImport(
    'ss://aes-256-gcm:secret@ss.example:8388?plugin=obfs-local;obfs=http;obfs-host=cdn.example#ss-plug');
assert('SIP002 plugin link parses', r.ok && r.fields.type === 'shadowsocks');
assert('SIP002 server',   r.fields.server === 'ss.example');
assert('SIP002 port',     r.fields.server_port === 8388);
assert('SIP002 method',   r.fields.shadowsocks_method === 'aes-256-gcm');
assert('SIP002 password', r.fields.server_password === 'secret');
assert('SIP002 plugin name (matches backend field)', r.fields.plugin === 'obfs-local');
assert('SIP002 plugin_opts (remainder after first \";\")',
    r.fields.plugin_opts === 'obfs=http;obfs-host=cdn.example');

// 2: ?plugin=name with NO opts → plugin set, plugin_opts absent.
r = mod.shareLinkImport('ss://aes-256-gcm:pw@ss.example:8388?plugin=v2ray-plugin#x');
assert('plugin-only name', r.ok && r.fields.plugin === 'v2ray-plugin');
assert('plugin-only no opts', !('plugin_opts' in r.fields));

// 3: base64 userinfo (legacy SIP002) WITH a ?plugin= query still works.
const b64 = Buffer.from('aes-256-gcm:secret', 'utf8').toString('base64');
r = mod.shareLinkImport('ss://' + b64 + '@ss.example:8388?plugin=obfs-local;obfs=tls#b64plug');
assert('b64 userinfo + plugin method', r.fields.shadowsocks_method === 'aes-256-gcm');
assert('b64 userinfo + plugin password', r.fields.server_password === 'secret');
assert('b64 userinfo + plugin name', r.fields.plugin === 'obfs-local');
assert('b64 userinfo + plugin opts', r.fields.plugin_opts === 'obfs=tls');

// 4: IPv6 bracket host + ?plugin= (query must not be swallowed into host).
r = mod.shareLinkImport('ss://aes-256-gcm:pw@[2001:db8::9]:8388?plugin=obfs-local;obfs=http#v6');
assert('IPv6 host + plugin host', r.ok && r.fields.server === '[2001:db8::9]');
assert('IPv6 host + plugin port', r.fields.server_port === 8388);
assert('IPv6 host + plugin name', r.fields.plugin === 'obfs-local');

// 5: NO query (plain link) — must NOT have plugin keys (no regression).
r = mod.shareLinkImport('ss://aes-128-gcm:mypass@ss2.example:8388#ss2');
assert('plain link parses', r.ok && r.fields.shadowsocks_method === 'aes-128-gcm');
assert('plain link no plugin key', !('plugin' in r.fields));
assert('plain link no plugin_opts key', !('plugin_opts' in r.fields));

console.log('ALL PASS: test_audit_9_3');
"
