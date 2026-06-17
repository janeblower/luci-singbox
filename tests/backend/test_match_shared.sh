#!/bin/sh
# tests/test_match_shared.sh — match.fields(ctx) returns clean field copies and
# excludes rule_set/inbound/auth_user/clash_mode from the headless context.
set -eu
. "$(dirname "$0")/../lib/sb_helpers.sh"
cd "$(dirname "$0")/../.."
UCODE_BIN="${UCODE_BIN:-ucode}"
LIB="${UCODE_LIB_DIR:-${SB_LIB}}"
command -v "$UCODE_BIN" >/dev/null 2>&1 || { echo "SKIP test_match_shared (ucode missing)"; exit 0; }

out=$("$UCODE_BIN" -L "$LIB" -e '
  let match = require("builder._shared.match");
  function names(a){ let o={}; for (let f in a) o[f.name]=1; return o; }
  let r = names(match.fields("route"));
  let h = names(match.fields("headless"));
  let ok = true;
  for (let n in ["domain_suffix","ip_cidr","port"]) ok = ok && r[n] && h[n];
  for (let n in ["rule_set","inbound","auth_user","clash_mode"]) ok = ok && r[n] && !h[n];
  let leaked = false;
  for (let f in match.fields("route")) if ("_ctx" in f) leaked = true;
  ok = ok && !leaked;
  print(ok ? "OK\n" : "BAD\n");
')
echo "$out"
echo "$out" | grep -q '^OK$' || { echo "FAIL"; exit 1; }
echo "test_match_shared: PASS"
