#!/bin/sh
set -eu
command -v node >/dev/null 2>&1 || { echo "SKIP: no node"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
DF="luci-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/lib/descriptor_form.js"
cat > "$WORK/t.js" <<'JS'
const fs=require('fs');
global._=(s)=>s; global.E=()=>({});
function FakeOpt(n){this.option=n;this.deps=[];this.readonly=false;this.title=n;}
FakeOpt.prototype.depends=function(d){this.deps.push(d);};
FakeOpt.prototype.value=function(){};
const form={Flag:FakeOpt,Value:FakeOpt,ListValue:FakeOpt,DynamicList:FakeOpt};
const uci={sections:()=>[]}, network={}, validators={};
const SbViewState={getCoreVersion:()=>'',getCompatOnly:()=>false};
const SbCommon={compareVersions:()=>0};
const section={ _opts:{}, option(W,name,label){const o=new W(name);o.title=label;this._opts[name]=o;return o;} };
let body=fs.readFileSync(process.argv[2],'utf8')
  .replace(/^'use strict';\s*/,'').replace(/'require [^']*';\s*/g,'')
  .replace(/return L\.Class\.extend\(/, 'return (');
const mod=new Function('form','ui','uci','network','validators','SbViewState','SbCommon',body)
  (form,{},uci,network,validators,SbViewState,SbCommon);
if(typeof mod.applyMaterializedNamed!=='function'){console.log('FAIL: no applyMaterializedNamed');process.exit(1);}
const mat={sing_box_type:'clash_api',tabs:['basic'],shared:{},fields:[
  {name:'secret',type:'string',tab:'basic',secret:true},
  {name:'listen',type:'string',tab:'basic',default:'127.0.0.1'},
  {name:'mode',type:'enum',tab:'basic',values:['','rule','global']},
]};
mod.applyMaterializedNamed(section,'clash_api','clash_api',mat);
if(!section._opts['secret']||!section._opts['listen']||!section._opts['mode']){console.log('FAIL: fields not created');process.exit(1);}
if(section._opts['listen'].default!=='127.0.0.1'){console.log('FAIL: default not applied');process.exit(1);}
console.log('PASS');
JS
node "$WORK/t.js" "$DF"
