#!/bin/sh
set -eu
command -v node >/dev/null 2>&1 || { echo "SKIP: no node"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
VS="luci-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/lib/view_state.js"
cat > "$WORK/t.js" <<'JS'
const fs = require('fs');
let body = fs.readFileSync(process.argv[2], 'utf8')
  .replace(/^'use strict';\s*/,'')
  .replace(/return L\.Class\.extend\(/, 'return (');
const L = { Class: { extend: (o) => o } };
const mod = eval('(function(){' + body + '})()');
if (typeof mod.getCompatOnly !== 'function') { console.log('FAIL: no getCompatOnly'); process.exit(1); }
if (mod.getCompatOnly() !== false) { console.log('FAIL: default not false'); process.exit(1); }
mod.setCompatOnly(true);
if (mod.getCompatOnly() !== true) { console.log('FAIL: setter'); process.exit(1); }
console.log('PASS');
JS
node "$WORK/t.js" "$VS"
