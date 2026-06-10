#!/bin/sh
# tests/test_transport_helper_js.sh — the transport-parsing block is shared
# (spec S2-QUAL): importers/transport.js exists and both importers route
# transport fields through it identically.
set -e
cd "$(dirname "$0")/.."
if ! command -v node >/dev/null 2>&1; then echo "SKIP: node not available" >&2; exit 0; fi

ROOT=luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui
HELPER="$ROOT/importers/transport.js"
[ -f "$HELPER" ] || { echo "FAIL: $HELPER missing"; exit 1; }

# Both importers must require the shared helper, not inline the block.
grep -q "importers.transport" "$ROOT/importers/inbound.js"  || { echo "FAIL: inbound.js does not require transport helper"; exit 1; }
grep -q "importers.transport" "$ROOT/importers/outbound.js" || { echo "FAIL: outbound.js does not require transport helper"; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat >"$TMP/run.js" <<'NODE'
const fs = require('fs'); const vm = require('vm'); const path = require('path');
function loadModule(filePath, extra) {
  const src = fs.readFileSync(filePath, 'utf8');
  const body = src
    .replace(/^'use strict';\s*/, '')
    .replace(/^'require [^']+';\s*/gm, '')
    .replace(/return L\.Class\.extend\((\{[\s\S]*\})\);?\s*$/, '__moduleExports = $1;');
  const sandbox = Object.assign({ __moduleExports:null, _:(s)=>s, Object:Object, Array:Array,
    String:String, Number:Number, console:console, L:{Class:{extend:(o)=>o}} }, extra||{});
  const ctx = vm.createContext(sandbox);
  vm.runInContext('(function(){'+body+'})();', ctx, { filename: path.basename(filePath) });
  return ctx.__moduleExports;
}
const root = process.argv[2];
const T = loadModule(path.join(root, 'importers/transport.js'));
let f=0; function ok(l,c){ if(c)console.log('  PASS:',l); else {console.log('  FAIL:',l);f++;} }
ok('parseTransport is a function', typeof T.parseTransport === 'function');

const o = { transport: { type: 'http', host: ['a.x','b.x'], path: '/api', mode: undefined } };
let fields = {}; T.parseTransport(o, fields);
ok('http multi-host -> transport_hosts list',
   Array.isArray(fields.transport_hosts) && fields.transport_hosts.length === 2);
ok('http sets transport + path', fields.transport === 'http' && fields.transport_path === '/api');

let f2 = {}; T.parseTransport({ transport: { type:'ws', host:'cdn.x', path:'/ws' } }, f2);
ok('ws host stays scalar', f2.transport_host === 'cdn.x' && f2.transport === 'ws');

let f3 = {}; T.parseTransport({ transport: { type:'xhttp', mode:'packet-up' } }, f3);
ok('xhttp mode routed', f3.transport_xhttp_mode === 'packet-up');

if(f){ console.error('test_transport_helper_js: '+f+' failure(s)'); process.exit(1); }
console.log('OK');
NODE
node "$TMP/run.js" "$ROOT"
