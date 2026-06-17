#!/bin/sh
# tests/test_protocol_parity.sh — production-path output must deep-equal the
# goldens captured (key-order agnostic) from the pre-refactor tree.
set -eu
. "$(dirname "$0")/lib/sb_helpers.sh"
cd "$(dirname "$0")/.."
UCODE_BIN="${UCODE_BIN:-ucode}"
LIB="${UCODE_LIB_DIR:-${SB_LIB}}"
command -v "$UCODE_BIN" >/dev/null 2>&1 || { echo "SKIP test_protocol_parity (ucode missing)"; exit 0; }

out=$("$UCODE_BIN" -L tests/parity -L "$LIB" -e '
    let fs = require("fs");
    let canon = require("canon").canon;
    let corpus = require("corpus");
    let ob = require("outbound");
    let inb = require("inbound");
    let fails = 0;
    for (let fx in corpus) {
        let got = (fx.kind === "outbound")
            ? ob.build_constructor_for(fx.section, fx.type)
            : inb.build_one(fx.section);
        let want_f = fs.open(sprintf("tests/parity/golden/%s.json", fx.name), "r");
        if (want_f == null) { print(sprintf("MISSING golden %s\n", fx.name)); fails++; continue; }
        let want = trim(want_f.read("all")); want_f.close();
        let g = sprintf("%J", canon(got));
        if (g !== want) { print(sprintf("DRIFT %s\n  got=%s\n  want=%s\n", fx.name, g, want)); fails++; }
    }
    print(fails === 0 ? "ALLOK\n" : sprintf("FAILS=%d\n", fails));
')
echo "$out"
echo "$out" | grep -q '^ALLOK$' || { echo "FAIL: parity drift"; exit 1; }
echo "test_protocol_parity: all PASS"
