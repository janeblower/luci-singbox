#!/bin/sh
# tests/test_settings_parity.sh — parity test for singleton settings descriptors
# (clash_api + cache).
# Uses filler.build(reg.get(kind, type), section) directly — no UCI cursor needed.
# Mirrors tests/test_dns_parity.sh but iterates settings_corpus (kind+type per fixture).
set -eu
. "$(dirname "$0")/lib/sb_helpers.sh"
cd "$(dirname "$0")/.."
UCODE_BIN="${UCODE_BIN:-ucode}"
LIB="${UCODE_LIB_DIR:-${SB_LIB}}"
command -v "$UCODE_BIN" >/dev/null 2>&1 || { echo "SKIP test_settings_parity (ucode missing)"; exit 0; }

out=$("$UCODE_BIN" -L tests/parity -L "$LIB" -e '
    let fs     = require("fs");
    let canon  = require("canon").canon;
    let corpus = require("settings_corpus");
    let reg    = require("builder.settings.registry");
    let filler = require("builder._filler");
    let fails  = 0;

    for (let fx in corpus) {
        let golden_path = sprintf("tests/parity/golden/%s.json", fx.name);
        let want_f = fs.open(golden_path, "r");
        if (want_f == null) {
            print(sprintf("SKIP (no golden yet): %s\n", fx.name));
            continue;
        }
        let want = trim(want_f.read("all")); want_f.close();

        let d = reg.get(fx.kind, fx.type);
        if (d == null) {
            print(sprintf("MISSING descriptor %s/%s for %s\n", fx.kind, fx.type, fx.name));
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
echo "$out" | grep -q '^ALLOK$' || { echo "FAIL: settings parity drift"; exit 1; }
echo "test_settings_parity: all PASS"
