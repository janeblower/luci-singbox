#!/bin/sh
# tests/test_view_state_js.sh — the schema cache must live in a module
# singleton (lib/view_state.js), not on window (spec S2-5).
set -e
. "$(dirname "$0")/../lib/sb_helpers.sh"
cd "$(dirname "$0")/../.."
if ! command -v node >/dev/null 2>&1; then echo "SKIP: node not available" >&2; exit 0; fi

ROOT=${SB_VIEW}
JS="$ROOT/lib/view_state.js"

[ -f "$JS" ] || { echo "FAIL: $JS missing"; exit 1; }

# Guard: no window.singboxUi* writes/reads remain anywhere in the view tree.
if grep -RHn "window\.singboxUi" "$ROOT" >/dev/null 2>&1; then
  echo "FAIL: leftover window.singboxUi* references:"
  grep -RHn "window\.singboxUi" "$ROOT"
  exit 1
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat >"$TMP/run.js" <<'NODE'
const fs = require('fs'); const vm = require('vm');
const src = fs.readFileSync(process.argv[2], 'utf8');
const body = src
  .replace(/^'use strict';\s*/, '')
  .replace(/^'require [^']+';\s*/gm, '')
  .replace(/return L\.Class\.extend\((\{[\s\S]*\})\);?\s*$/, '__moduleExports = $1;');
const sandbox = { __moduleExports:null, L:{Class:{extend:(o)=>o}}, Object:Object, console:console };
const ctx = vm.createContext(sandbox);
vm.runInContext('(function(){'+body+'})();', ctx, { filename:'view_state.js' });
const VS = ctx.__moduleExports;
let f=0; function ok(l,c){ if(c)console.log('  PASS:',l); else {console.log('  FAIL:',l);f++;} }
ok('exports getSchema/setSchema', typeof VS.getSchema==='function' && typeof VS.setSchema==='function');
VS.setSchema({ inbound: { tproxy: {} } });
ok('schema round-trips', VS.getSchema().inbound.tproxy !== undefined);
if(f){ console.error('test_view_state_js: '+f+' failure(s)'); process.exit(1); }
console.log('OK');
NODE
node "$TMP/run.js" "$JS"
