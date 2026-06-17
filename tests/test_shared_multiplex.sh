#!/bin/sh
# tests/test_shared_multiplex.sh — declarative emit_spec path via filler for
# the shared multiplex block.
set -eu; cd "$(dirname "$0")/.."
. "$(dirname "$0")/lib/sb_helpers.sh"
UCODE_BIN="${UCODE_BIN:-ucode}"; UCODE_LIB_DIR="${UCODE_LIB_DIR:-${SB_LIB}}"
command -v "$UCODE_BIN" >/dev/null 2>&1 || { echo "SKIP test_shared_multiplex"; exit 0; }
je() { "$UCODE_BIN" -L "$UCODE_LIB_DIR" -e "$1"; }

# Helper: build multiplex block via filler
# f.build({kind:"outbound",sing_box_type:"x",fields:[],shared:{multiplex:true}}, s)
# → got.multiplex (or null when disabled)

# Test 1: disabled → no multiplex key.
out=$(je '
    let f = require("builder._filler");
    let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ multiplex:true } },
        { ".name":"t", multiplex_enabled:"0" }
    );
    print(got.multiplex == null ? "NULL" : "X");
')
[ "$out" = "NULL" ] || { echo "FAIL: disabled"; exit 1; }

# Test 2: enabled default protocol smux.
out=$(je '
    let f = require("builder._filler");
    let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ multiplex:true } },
        { ".name":"t", multiplex_enabled:"1" }
    );
    print(sprintf("%s|%s", got.multiplex.enabled, got.multiplex.protocol));
')
[ "$out" = "true|smux" ] || { echo "FAIL: default smux [$out]"; exit 1; }

# Test 3: full advanced.
out=$(je '
    let f = require("builder._filler");
    let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ multiplex:true } },
        { ".name":"t", multiplex_enabled:"1", multiplex_protocol:"yamux",
          multiplex_max_connections:"4", multiplex_min_streams:"4",
          multiplex_max_streams:"8", multiplex_padding:"1" }
    );
    print(sprintf("%s|%d|%d|%d|%s",
        got.multiplex.protocol, got.multiplex.max_connections,
        got.multiplex.min_streams, got.multiplex.max_streams, got.multiplex.padding));
')
[ "$out" = "yamux|4|4|8|true" ] || { echo "FAIL: advanced [$out]"; exit 1; }

echo "ALL PASS: test_shared_multiplex"
