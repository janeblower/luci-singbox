#!/bin/sh
# tests/test_common_version_gate_js.sh — node tests for applyVersionGate in common.js.
# Exercises min_version gating (requires X.Y+) and max_version gating (removed in X.Y).
set -eu
command -v node >/dev/null 2>&1 || { echo "SKIP: no node"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
CM="luci-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/lib/common.js"
cat > "$WORK/t.js" <<'JS'
const fs=require('fs');
global._=(s)=>s; global.E=()=>({});
const form={}, uci={}, ui={};
let body=fs.readFileSync(process.argv[2],'utf8')
  .replace(/^'use strict';\s*/,'').replace(/'require [^']*';\s*/g,'')
  .replace(/return L\.Class\.extend\(/, 'return (');
const mod=new Function('form','uci','ui',body)(form,uci,ui);

// a: min_version 1.14 — gated when core=1.12 (core < 1.14)
// b: max_version 1.11 — gated when core=1.12 (core > 1.11, type was removed)
// c: no gate
const schema={ a:{min_version:'1.14'}, b:{max_version:'1.11'}, c:{} };
function mkSelect(){ const opts=[{value:'a',disabled:false,textContent:'a'},
  {value:'b',disabled:false,textContent:'b'},{value:'c',disabled:false,textContent:'c'}];
  return {tagName:'SELECT',options:opts,querySelector:()=>null}; }
const o={ renderWidget:function(){ return mkSelect(); }, value:function(){}, validate:null };
mod.applyVersionGate(o, schema, '1.12', false);  // compatOnly OFF
let node=o.renderWidget();
const a=node.options.find(x=>x.value==='a'), b=node.options.find(x=>x.value==='b'), c=node.options.find(x=>x.value==='c');
if(!a.disabled || !/requires 1\.14/.test(a.textContent)){console.log('FAIL min: '+a.textContent);process.exit(1);}
if(!b.disabled || !/removed in 1\.11/.test(b.textContent)){console.log('FAIL max: '+b.textContent);process.exit(1);}
if(c.disabled){console.log('FAIL: in-window option disabled');process.exit(1);}

// compatOnly=true: gated options are removed entirely
const o2={ renderWidget:function(){ return mkSelect(); }, value:function(){}, validate:null };
mod.applyVersionGate(o2, schema, '1.12', true);
let node2=o2.renderWidget();
// After compatOnly removal, sel.options should only contain 'c'
// (parent.removeChild removes them from the array in our mock if parentNode is set)
// We test via validate: gated values should still be rejected
const validResult=o2.validate(null, 'a');
if(validResult===true){console.log('FAIL: compatOnly validate did not reject gated value');process.exit(1);}
const validOk=o2.validate(null, 'c');
if(validOk!==true){console.log('FAIL: validate rejected in-window value: '+validOk);process.exit(1);}

console.log('PASS');
JS
node "$WORK/t.js" "$CM"
echo "PASS: test_common_version_gate_js"
