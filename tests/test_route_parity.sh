#!/bin/sh
# tests/test_route_parity.sh — semantic parity for route_rule / rule_set builders
# against hand-verified goldens (canon-normalized, order-agnostic).
set -eu
. "$(dirname "$0")/lib/sb_helpers.sh"
cd "$(dirname "$0")/.."
UCODE_BIN="${UCODE_BIN:-ucode}"
LIB="${UCODE_LIB_DIR:-${SB_LIB}}"
command -v "$UCODE_BIN" >/dev/null 2>&1 || { echo "SKIP test_route_parity (ucode missing)"; exit 0; }

out=$("$UCODE_BIN" -L tests/parity -L "$LIB" -e '
  let uci_mod = require("uci");
  let fs      = require("fs");
  let canon   = require("canon").canon;
  let corpus  = require("route_corpus");
  let route   = require("route");
  let ruleset = require("ruleset");
  let dns     = require("dns");
  let fails = 0;

  function write_uci(sections, dir) {
    fs.mkdir(dir);
    let lines = [];
    for (let sec in sections) {
      push(lines, sprintf("config %s %s%s%s", sec.type, chr(39), sec.name, chr(39)));
      for (let k in keys(sec.opts)) push(lines, sprintf("\toption %s %s%s%s", k, chr(39), sec.opts[k], chr(39)));
      for (let k in keys(sec.lists))
        for (let v in sec.lists[k]) push(lines, sprintf("\tlist %s %s%s%s", k, chr(39), v, chr(39)));
    }
    let f = fs.open(sprintf("%s/singbox-ui", dir), "w");
    f.write(join("\n", lines) + "\n"); f.close();
  }

  for (let fx in corpus) {
    let golden_path = sprintf("tests/parity/golden/%s.json", fx.name);
    let want_f = fs.open(golden_path, "r");
    // A corpus fixture without a golden is a hard FAILURE (matches
    // test_protocol_parity.sh), not a silent SKIP: a silently-passing fixture
    // gives no coverage AND its SKIP line would erode run.sh MAX_SKIPS budget.
    if (want_f == null) { print(sprintf("MISSING golden %s\n", fx.name)); fails++; continue; }
    let want = trim(want_f.read("all")); want_f.close();

    let dir = sprintf("/tmp/route_par_%s", fx.name);
    write_uci(fx.sections, dir);
    let cur = uci_mod.cursor(dir);
    let got = null;
    if (fx.kind == "rule") {
      let r = route.build_route_rules(cur, null);
      got = (length(r.rules) > 0) ? r.rules[0] : null;
    } else {
      let r = route.build_route_rules(cur, null);
      let referenced = r.referenced;
      let seen = {}; for (let n in referenced) seen[n] = true;
      for (let n in dns.referenced_rulesets(cur)) if (!seen[n]) { push(referenced, n); seen[n] = true; }
      let sets = ruleset.build_rule_sets(cur, referenced);
      for (let e in sets) if (e.tag == fx.tag) got = e;
    }
    if (got == null) { print(sprintf("MISSING %s\n", fx.name)); fails++; continue; }
    let g = sprintf("%J", canon(got));
    if (g != want) { print(sprintf("DRIFT %s\n  got =%s\n  want=%s\n", fx.name, g, want)); fails++; }
  }
  print(fails == 0 ? "ALLOK\n" : sprintf("FAILS=%d\n", fails));
')
echo "$out"
echo "$out" | grep -q "^ALLOK$" || { echo "FAIL: route parity drift"; exit 1; }
echo "test_route_parity: all PASS"
