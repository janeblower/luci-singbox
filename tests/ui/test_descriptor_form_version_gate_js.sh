#!/bin/sh
set -eu
. "$(dirname "$0")/../lib/sb_helpers.sh"
command -v node >/dev/null 2>&1 || { echo "SKIP: no node"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
DF="${SB_VIEW}/lib/descriptor_form.js"
cat > "$WORK/t.js" <<'JS'
const fs = require('fs');
global._ = (s) => s;
global.E = () => ({});
function FakeOpt(name){ this.option=name; this.deps=[]; this.readonly=false; this.title=name; }
FakeOpt.prototype.depends=function(d){ this.deps.push(d); };
FakeOpt.prototype.value=function(){};
const form = { Flag:FakeOpt, Value:FakeOpt, ListValue:FakeOpt, DynamicList:FakeOpt };
const uci = { sections:()=>[] };
const network = {};
const validators = {};
let compatOnly=false, core='1.12';
const SbViewState = { getCoreVersion:()=>core, getCompatOnly:()=>compatOnly };
const SbCommon = { compareVersions:(a,b)=>{a=String(a).split('.').map(Number);b=String(b).split('.').map(Number);for(let i=0;i<3;i++){const x=a[i]||0,y=b[i]||0;if(x>y)return 1;if(x<y)return -1;}return 0;} };
const section = {
  _opts:{}, tabs:[], _sbMatRegistry:{},
  tab(){}, taboption(tab,W,name,label){ const o=new W(name); o.title=label; this._opts[name]=o; return o; },
};
let body = fs.readFileSync(process.argv[2],'utf8')
  .replace(/^'use strict';\s*/,'')
  .replace(/'require [^']*';\s*/g,'')
  .replace(/return L\.Class\.extend\(/, 'return (');
const mod = new Function('form','ui','uci','network','validators','SbViewState','SbCommon', body)
  (form,{},uci,network,validators,SbViewState,SbCommon);
function mat(fields){ return { sing_box_type:'x', tabs:['basic'], shared:{}, fields:fields }; }
// A: min gate, compatOnly OFF -> created + readonly + note.
compatOnly=false; core='1.12';
mod.applyMaterialized(section,'dns','x', mat([{name:'f1',type:'string',tab:'basic',min_version:'1.13'}]));
let o = section._opts['f1'];
if (!o) { console.log('FAIL A: not created'); process.exit(1); }
if (o.readonly !== true) { console.log('FAIL A: not readonly'); process.exit(1); }
if (!/requires 1\.13/.test(o.title)) { console.log('FAIL A: no note: '+o.title); process.exit(1); }
// B: min gate, compatOnly ON -> NOT created.
section._opts={}; section._sbMatRegistry={}; compatOnly=true; core='1.12';
mod.applyMaterialized(section,'dns','x', mat([{name:'f2',type:'string',tab:'basic',min_version:'1.13'}]));
if (section._opts['f2']) { console.log('FAIL B: created under compatOnly'); process.exit(1); }
// C: max gate, compatOnly OFF, core newer -> readonly + removed note.
section._opts={}; section._sbMatRegistry={}; compatOnly=false; core='1.14';
mod.applyMaterialized(section,'dns','x', mat([{name:'f3',type:'string',tab:'basic',max_version:'1.13'}]));
o = section._opts['f3'];
if (!o || o.readonly !== true || !/removed in 1\.13/.test(o.title)) { console.log('FAIL C'); process.exit(1); }
// D: in-window -> normal (not readonly).
section._opts={}; section._sbMatRegistry={}; compatOnly=false; core='1.13';
mod.applyMaterialized(section,'dns','x', mat([{name:'f4',type:'string',tab:'basic',min_version:'1.13'}]));
o = section._opts['f4'];
if (!o || o.readonly === true) { console.log('FAIL D: in-window gated'); process.exit(1); }
console.log('PASS');
JS
node "$WORK/t.js" "$DF"
