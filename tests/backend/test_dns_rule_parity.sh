#!/bin/sh
# tests/test_dns_rule_parity.sh — semantic parity for dns_rule descriptors
# (default/logical) against hand-verified goldens (canon-normalized, order-agnostic).
# Single-rule filler output only; logical inlining is covered by test_dns_rule_dispatch.sh.
set -eu
. "$(dirname "$0")/../lib/sb_helpers.sh"
cd "$(dirname "$0")/../.."
UCODE_BIN="${UCODE_BIN:-ucode}"
LIB="${UCODE_LIB_DIR:-${SB_LIB}}"
command -v "$UCODE_BIN" >/dev/null 2>&1 || { echo "SKIP test_dns_rule_parity (ucode missing)"; exit 0; }

out=$("$UCODE_BIN" -L tests/parity -L "$LIB" -e '
    let fs     = require("fs");
    let canon  = require("canon").canon;
    let corpus = require("dns_rule_corpus");
    let reg    = require("builder.dns_rule.registry");
    let filler = require("builder._filler");
    let fails  = 0;

    for (let fx in corpus) {
        let golden_path = sprintf("tests/parity/golden/%s.json", fx.name);
        let want_f = fs.open(golden_path, "r");
        if (want_f == null) {
            print(sprintf("MISSING golden %s\n", fx.name));
            fails++;
            continue;
        }
        let want = trim(want_f.read("all")); want_f.close();

        let d = reg.get("dns_rule", fx.type);
        if (d == null) {
            print(sprintf("MISSING descriptor dns_rule/%s for %s\n", fx.type, fx.name));
            fails++;
            continue;
        }

        let got = filler.build(d, fx.section);
        if (got == null) {
            print(sprintf("NULL output for %s\n", fx.name));
            fails++;
            continue;
        }

        let g = sprintf("%J", canon(got));
        if (g !== want) {
            print(sprintf("DRIFT %s\n  got =%s\n  want=%s\n", fx.name, g, want));
            let act = fs.open(sprintf("tests/parity/golden/%s.json.actual", fx.name), "w");
            act.write(g + "\n"); act.close();
            fails++;
        }
    }
    print(fails === 0 ? "ALLOK\n" : sprintf("FAILS=%d\n", fails));
')
echo "$out"
echo "$out" | grep -q '^ALLOK$' || { echo "FAIL: dns_rule parity drift"; exit 1; }
echo "test_dns_rule_parity: all PASS"
