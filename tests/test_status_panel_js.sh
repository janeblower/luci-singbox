#!/bin/sh
# tests/test_status_panel_js.sh — asserts renderStatusPanel handles RPC failure
# (S2-1): a rejected callStatus() must not reject the returned promise.
set -e
cd "$(dirname "$0")/.."
if ! command -v node >/dev/null 2>&1; then echo "SKIP: node not available" >&2; exit 0; fi

JS=luci-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/widgets/status-panel.js
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/run.js" <<'NODE'
const fs = require('fs'); const vm = require('vm');
const src = fs.readFileSync(process.argv[2], 'utf8');
const body = src
  .replace(/^'use strict';\s*/, '')
  .replace(/^'require [^']+';\s*/gm, '')
  .replace(/return L\.Class\.extend\((\{[\s\S]*\})\);?\s*$/, '__moduleExports = $1;');
function E(tag, a, c){ const el={tag,_t:'',children:[],appendChild(x){if(x)this.children.push(x);return x;},
  set innerHTML(v){if(v==='')this.children=[];}, get innerHTML(){return '';},
  get textContent(){let t=this._t;for(const k of this.children)t+=(k&&k.textContent)||'';return t;}};
  function add(x){if(x==null)return; if(Array.isArray(x)){x.forEach(add);return;} if(typeof x==='string'){el._t+=x;return;} el.children.push(x);}
  let kids=c; if(a&&typeof a==='object'&&!Array.isArray(a)&&a.tag===undefined){} else kids=a; add(kids); return el; }
let statusImpl = () => Promise.resolve({ status: 'ok', running: true, now: 0 });
const sandbox = { __moduleExports:null, _:(s)=>s, E:E, L:{Class:{extend:(o)=>o}},
  Math:Math, Object:Object, Array:Array, Promise:Promise, Number:Number, String:String, console:console,
  SbRpc:{ callStatus:(...a)=>statusImpl(...a) },
  __test:{ setStatus:(fn)=>{statusImpl=fn;} } };
const ctx = vm.createContext(sandbox);
vm.runInContext('(function(){'+body+'})();', ctx, { filename:'status-panel.js' });
const SP = ctx.__moduleExports;
let failures=0; function ok(l,c){ if(c)console.log('  PASS:',l); else {console.log('  FAIL:',l);failures++;} }
(async function(){
  ctx.__test.setStatus(() => Promise.reject(new Error('rpcd gone')));
  const holder = E('div', {});
  let rejected=false;
  await SP.renderStatusPanel(holder).catch(()=>{rejected=true;});
  ok('renderStatusPanel swallows RPC rejection (S2-1)', rejected===false);
  if(failures){ console.error('test_status_panel_js: '+failures+' failure(s)'); process.exit(1); }
  console.log('OK');
})().catch((e)=>{console.error('harness error',e);process.exit(1);});
NODE
node "$TMP/run.js" "$JS"
