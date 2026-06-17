#!/bin/sh
# tests/test_common_notify_js.sh — notify() must not TypeError when the
# rejection reason is null/undefined (spec S2-7).
set -e
. "$(dirname "$0")/lib/sb_helpers.sh"
cd "$(dirname "$0")/.."
if ! command -v node >/dev/null 2>&1; then echo "SKIP: node not available" >&2; exit 0; fi

JS=${SB_VIEW}/lib/common.js
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/run.js" <<'NODE'
const fs = require('fs'); const vm = require('vm');
const src = fs.readFileSync(process.argv[2], 'utf8');
const body = src
  .replace(/^'use strict';\s*/, '')
  .replace(/^'require [^']+';\s*/gm, '')
  .replace(/return L\.Class\.extend\((\{[\s\S]*\})\);?\s*$/, '__moduleExports = $1;');
const notes = [];
const sandbox = { __moduleExports:null, _:(s)=>s,
  E:(t,c)=>({tag:t, _t: typeof c==='string'?c:'' }),
  L:{Class:{extend:(o)=>o}},
  ui:{ addNotification:(_a, node, _kind)=>notes.push(node && node._t),
       showModal(){}, hideModal(){} },
  form:{ Value:function(){}, ListValue:function(){} },
  uci:{ sections:()=>[], rename(){} },
  Promise:Promise, Object:Object, Array:Array, document:{ body:{appendChild(){},removeChild(){}} },
  window:{}, console:console };
const ctx = vm.createContext(sandbox);
vm.runInContext('(function(){'+body+'})();', ctx, { filename:'common.js' });
const C = ctx.__moduleExports;
let f=0; function ok(l,c){ if(c)console.log('  PASS:',l); else {console.log('  FAIL:',l);f++;} }
(async function(){
  let threw=false;
  await C.notify(Promise.reject(null), 'ok', 'Failed').catch(()=>{threw=true;});
  ok('notify() does not throw on null rejection (S2-7)', threw===false);
  ok('notify() still posts a danger notification (S2-7)',
     notes.some(t => typeof t==='string' && t.indexOf('Failed') >= 0));
  if(f){ console.error('test_common_notify_js: '+f+' failure(s)'); process.exit(1); }
  console.log('OK');
})().catch((e)=>{console.error('harness error',e);process.exit(1);});
NODE
node "$TMP/run.js" "$JS"
