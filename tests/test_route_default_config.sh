#!/bin/sh
# tests/test_route_default_config.sh — guard the SHIPPED default UCI config
# (etc/config/singbox-ui) against the route schema. The synthetic parity corpus
# uses hand-written fixtures, so it cannot catch a stale default config; this
# test runs route.uc/ruleset.uc against the real shipped config and asserts the
# emitted route block uses only valid sing-box rule actions and resolves its
# rule-set references. (Caught a fresh-install-breaking stale default once.)
set -eu
. "$(dirname "$0")/lib/sb_helpers.sh"
cd "$(dirname "$0")/.."
UCODE_BIN="${UCODE_BIN:-ucode}"
LIB="${UCODE_LIB_DIR:-${SB_LIB}}"
CFG="${SB_BACKEND_ROOT}/etc/config/singbox-ui"
command -v "$UCODE_BIN" >/dev/null 2>&1 || { echo "SKIP test_route_default_config (ucode missing)"; exit 0; }

out=$("$UCODE_BIN" -L "$LIB" -e '
  let uci = require("uci");
  let fs  = require("fs");
  let route   = require("route");
  let ruleset = require("ruleset");
  let dns     = require("dns");

  // Stage the shipped config as a UCI fixture dir named after the package.
  let dir = "/tmp/route_default_cfg";
  fs.mkdir(dir);
  let src = fs.open("'"$CFG"'", "r");
  let body = src.read("all"); src.close();
  let dst = fs.open(sprintf("%s/singbox-ui", dir), "w");
  dst.write(body); dst.close();

  let cur = uci.cursor(dir);
  let r = route.build_route_rules(cur, null);

  const VALID = { route:1, "route-options":1, reject:1, "hijack-dns":1, sniff:1, resolve:1 };
  let ok = (length(r.rules) > 0);

  // Every emitted rule must carry a valid sing-box action.
  for (let rule in r.rules) {
    if (!VALID[rule.action]) { print(sprintf("BAD action %J\n", rule)); ok = false; }
  }

  // The shipped defaults_direct rule -> action route, outbound direct_wan,
  // rule_set [russia_inside, discord].
  let found = null;
  for (let rule in r.rules) if (rule.outbound === "direct_wan" && rule.action === "route") found = rule;
  ok = ok && (found != null);
  ok = ok && (found != null && type(found.rule_set) === "array" && length(found.rule_set) === 2);

  // route_default -> final direct_wan.
  ok = ok && (r.final === "direct_wan");

  // referenced must include both shipped rulesets; build_rule_sets must emit them.
  let refset = {}; for (let n in r.referenced) refset[n] = true;
  ok = ok && refset["russia_inside"] && refset["discord"];
  let sets = ruleset.build_rule_sets(cur, r.referenced);
  let tags = {}; for (let e in sets) tags[e.tag] = true;
  ok = ok && tags["russia_inside"] && tags["discord"];

  print(ok ? "OK\n" : sprintf("FAILED rules=%J final=%J referenced=%J\n", r.rules, r.final, r.referenced));
')
echo "$out"
echo "$out" | grep -q "^OK$" || { echo "FAIL: shipped default config route block invalid"; exit 1; }
echo "test_route_default_config: PASS"
