#!/bin/sh
# tests/test_dashboard_js.sh — node sandbox for tabs/dashboard.js.
# Mirrors tests/test_monitoring_js.sh: load the view fragment into a vm context
# with minimal DOM/LuCI/SbRpc stubs and assert rendering + behavior without any
# test-only hooks in the production source.
set -e
cd "$(dirname "$0")/.."
if ! command -v node >/dev/null 2>&1; then echo "SKIP: node not available" >&2; exit 0; fi

JS=luci-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/tabs/dashboard.js
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/run.js" <<'NODE'
const fs = require('fs'); const vm = require('vm');
const src = fs.readFileSync(process.argv[2], 'utf8');
const body = src
  .replace(/^'use strict';\s*/, '')
  .replace(/^'require [^']+';\s*/gm, '')
  .replace(/return L\.Class\.extend\((\{[\s\S]*\})\);?\s*$/, '__moduleExports = $1;');

if (!String.prototype.format) {
  String.prototype.format = function () { var a = arguments, i = 0;
    return this.replace(/%[sd]/g, function () { return String(a[i++]); }); };
}

let intervalId=0, timeoutId=0; const intervals={}, timeouts={};
function makeEl(tag){const el={tag,children:[],attrs:{},_text:'',isConnected:true,
  appendChild(c){if(c)this.children.push(c);return c;},
  set innerHTML(v){if(v==='')this.children=[];}, get innerHTML(){return '';},
  set textContent(v){this._text=String(v);this.children=[];},
  get textContent(){let t=this._text||'';for(const c of this.children)t+=(c&&c.textContent)||'';return t;},
  querySelectorAll(){return [];},
  set className(v){this.attrs['class']=String(v);}, get className(){return this.attrs['class']||'';}};
  return el;}
function E(tag,a,c){const el=makeEl(tag);let kids=c;
  if(a&&typeof a==='object'&&!Array.isArray(a)&&a.tag===undefined)el.attrs=a;else kids=a;
  (function add(x){if(x==null)return;if(Array.isArray(x)){x.forEach(add);return;}
    if(typeof x==='string'){el._text+=x;return;}el.children.push(x);})(kids);
  return el;}

let clashGet=()=>Promise.resolve({status:'ok',body:'{}'});
let clashMutate=()=>Promise.resolve({status:'ok'});
let clashDelay=()=>Promise.resolve({status:'ok',body:'{"delay":0}'});
let subStatus=()=>Promise.resolve([]);
let clashRefresh=()=>Promise.resolve({status:'ok'});

const sandbox={ __moduleExports:null, _:(s)=>s, E,
  L:{Class:{extend:(o)=>o}},
  ui:{createHandlerFn:(ctx,fn)=>fn, addNotification:()=>{}},
  document:{visibilityState:'visible',addEventListener(){},removeEventListener(){}},
  window:{addEventListener(){},removeEventListener(){}},
  setInterval:(fn,ms)=>{const id=++intervalId;intervals[id]={fn,ms};return id;},
  clearInterval:(id)=>{delete intervals[id];},
  setTimeout:(fn)=>{const id=++timeoutId;timeouts[id]=fn;return id;},
  clearTimeout:(id)=>{delete timeouts[id];},
  Math,Object,Array,JSON,Promise,Number,String,console,Date,
  SbRpc:{ callClashGet:(...a)=>clashGet(...a), callClashMutate:(...a)=>clashMutate(...a),
          callClashDelay:(...a)=>clashDelay(...a), callSubStatus:(...a)=>subStatus(...a),
          callRefresh:(...a)=>clashRefresh(...a) },
  __test:{ intervals, timeouts,
    setGet:(fn)=>{clashGet=fn;}, setMutate:(fn)=>{clashMutate=fn;},
    setDelay:(fn)=>{clashDelay=fn;}, setSub:(fn)=>{subStatus=fn;},
    setRefresh:(fn)=>{clashRefresh=fn;},
    fireInterval:(id)=>intervals[id]&&intervals[id].fn(),
    find(n,p){if(!n)return null;if(p(n))return n;for(const k of (n.children||[])){const r=this.find(k,p);if(r)return r;}return null;},
    findAll(n,p,out){out=out||[];if(!n)return out;if(p(n))out.push(n);for(const k of (n.children||[]))this.findAll(k,p,out);return out;} },
};
// Remove host String from sandbox so vm.createContext uses its own intrinsic
// String — then we can patch String.prototype.format inside the context.
delete sandbox.String;
const ctx=vm.createContext(sandbox);
// Patch the vm's own intrinsic String.prototype.format (safe: no shadowing now)
vm.runInContext('if(!String.prototype.format){String.prototype.format=function(){var a=arguments,i=0;return this.replace(/%[sd]/g,function(){return ""+a[i++];});};}',ctx);
vm.runInContext('(function(){'+body+'})();',ctx,{filename:'dashboard.js'});
const Dash=ctx.__moduleExports;
let failures=0;
function ok(l,c){if(c)console.log('  PASS:',l);else{console.log('  FAIL:',l);failures++;}}

(async function(){
  // --- widgets render from /connections + /version ---
  ctx.__test.setGet((path)=>{
    if(path==='/connections')return Promise.resolve({status:'ok',
      body:JSON.stringify({connections:[{id:'1'},{id:'2'}],downloadTotal:2048,uploadTotal:1024})});
    if(path==='/version')return Promise.resolve({status:'ok',body:'{"version":"1.12.0"}'});
    if(path==='/proxies')return Promise.resolve({status:'ok',body:'{"proxies":{}}'});
    return Promise.resolve({status:'ok',body:'{}'});
  });
  const d=Dash.buildDashboard();
  await d.poll();
  const txt=d.node.textContent;
  ok('active connections count rendered', txt.indexOf('2')>=0);
  ok('core version rendered', txt.indexOf('1.12.0')>=0);

  // --- unreachable when clash down ---
  ctx.__test.setGet(()=>Promise.reject(new Error('down')));
  const d2=Dash.buildDashboard();
  let rejected=false; await d2.poll().catch(()=>{rejected=true;});
  ok('poll() swallows rejection', rejected===false);
  ok('shows enable-in-settings on failure', d2.node.textContent.indexOf('Clash API')>=0);

  // --- interval self-cancels when detached ---
  ctx.__test.setGet(()=>Promise.resolve({status:'ok',body:'{"connections":[]}'}));
  const d3=Dash.buildDashboard(); d3.start();
  const ids=Object.keys(ctx.__test.intervals);
  ok('start registers an interval', ids.length>=1);
  d3.node.isConnected=false; ctx.__test.fireInterval(ids[0]);
  ok('interval clears itself when root detached', Object.keys(ctx.__test.intervals).length===0);

  // --- proxy groups render from /proxies ---
  const PROXIES = { proxies: {
    'GW':   { type:'Selector', now:'A', all:['A','B'] },
    'A':    { type:'Shadowsocks', history:[{delay:120}] },
    'B':    { type:'Vmess', history:[{delay:900}] },
    'AUTO': { type:'URLTest', now:'A', all:['A','B'] }
  }};
  ctx.__test.setGet((path)=>{
    if(path==='/proxies')return Promise.resolve({status:'ok',body:JSON.stringify(PROXIES)});
    if(path==='/connections')return Promise.resolve({status:'ok',body:'{"connections":[]}'});
    if(path==='/version')return Promise.resolve({status:'ok',body:'{"version":"1.12.0"}'});
    return Promise.resolve({status:'ok',body:'{}'});
  });
  const g=Dash.buildDashboard();
  await g.poll();                       // connections+version
  await g.refreshProxies();            // force-fetch /proxies
  const isGroup=(n)=>n.attrs&&/sb-dashboard-group\b/.test(n.attrs['class']||'');
  ok('renders selector + urltest groups', ctx.__test.findAll(g.node,isGroup).length===2);
  const isCurrent=(n)=>n.attrs&&/sb-dashboard-node-current/.test(n.attrs['class']||'');
  ok('highlights current node', ctx.__test.findAll(g.node,isCurrent).length>=2);
  const hasGood=ctx.__test.find(g.node,(n)=>n.attrs&&/sb-lat-good/.test(n.attrs['class']||''));
  const hasBad =ctx.__test.find(g.node,(n)=>n.attrs&&/sb-lat-bad/.test(n.attrs['class']||''));
  ok('latency badge colored good (<300)', !!hasGood);
  ok('latency badge colored bad (>=800)', !!hasBad);
  const urltestRows=ctx.__test.findAll(g.node,(n)=>n.attrs&&/sb-dashboard-node\b/.test(n.attrs['class']||'')&&n.attrs['data-group']==='AUTO');
  ok('urltest rows are read-only (no click handler)',
     urltestRows.length>=1 && urltestRows.every((r)=>typeof r.attrs.click!=='function'));

  // --- selector switch sends PUT /proxies/<group> {name} ---
  let putPath=null, putBody=null;
  ctx.__test.setMutate((method,path,bodyStr)=>{ putPath=method+' '+path; putBody=bodyStr;
    return Promise.resolve({status:'ok'}); });
  const s=Dash.buildDashboard();
  await s.poll(); await s.refreshProxies();
  const aRow=ctx.__test.find(s.node,(n)=>n.attrs&&n.attrs['data-group']==='GW'&&n.attrs['data-name']==='B'&&typeof n.attrs.click==='function');
  ok('selector member B is clickable', !!aRow);
  await aRow.attrs.click();
  ok('selector click PUTs /proxies/GW', putPath==='PUT /proxies/GW');
  ok('selector click body is {name:B}', JSON.parse(putBody).name==='B');

  // --- latency test calls callClashDelay per member ---
  const tested=[];
  ctx.__test.setDelay((args)=>{ tested.push(args.name);
    return Promise.resolve({status:'ok',body:JSON.stringify({delay:42})}); });
  const t=Dash.buildDashboard();
  await t.poll(); await t.refreshProxies();
  const testBtn=ctx.__test.find(t.node,(n)=>n.tag==='button'&&/sb-dashboard-test/.test((n.attrs&&n.attrs['class'])||'')&&typeof n.attrs.click==='function');
  await testBtn.attrs.click();
  ok('Test probes each member', tested.indexOf('A')>=0 && tested.indexOf('B')>=0);

  // --- sort-by-latency reorders members fastest-first ---
  const so=Dash.buildDashboard();
  so.setSortByLatency(true);
  await so.poll(); await so.refreshProxies();
  const names=ctx.__test.findAll(so.node,(n)=>n.attrs&&/sb-dashboard-node-name/.test(n.attrs['class']||'')).map((n)=>n.textContent);
  ok('sorted fastest-first (A before B)', names.indexOf('A')>=0 && names.indexOf('A')<names.indexOf('B'));

  // --- subscription status strip + Update button on subscription groups ---
  const PX2={proxies:{ 'mysub':{type:'Selector',now:'A',all:['A']}, 'A':{type:'Vmess',history:[{delay:50}]} }};
  ctx.__test.setGet((path)=>{
    if(path==='/proxies')return Promise.resolve({status:'ok',body:JSON.stringify(PX2)});
    if(path==='/connections')return Promise.resolve({status:'ok',body:'{"connections":[]}'});
    if(path==='/version')return Promise.resolve({status:'ok',body:'{"version":"1.12.0"}'});
    return Promise.resolve({status:'ok',body:'{}'});
  });
  ctx.__test.setSub(()=>Promise.resolve({status:'ok',subscriptions:[
    {name:'mysub',enabled:'1',last_update: Math.floor(Date.now()/1000)-120, node_count:7}
  ]}));
  let refreshed=null;
  ctx.__test.setRefresh((what,name)=>{ refreshed=what+':'+name; return Promise.resolve({status:'ok'}); });
  const sd=Dash.buildDashboard();
  await sd.poll(); await sd.refreshProxies(); await sd.refreshSubs();
  const stripTxt=sd.node.textContent;
  ok('subscription node count shown', stripTxt.indexOf('7')>=0);
  const upd=ctx.__test.find(sd.node,(n)=>n.tag==='button'&&/sb-dashboard-sub-update/.test((n.attrs&&n.attrs['class'])||'')&&typeof n.attrs.click==='function');
  ok('Update button rendered on subscription group', !!upd);
  await upd.attrs.click();
  ok('Update button calls refresh(subscriptions, mysub)', refreshed==='subscriptions:mysub');

  process.exit(failures?1:0);
})();
NODE

node "$TMP/run.js" "$JS"
echo "PASS: dashboard.js node checks"
