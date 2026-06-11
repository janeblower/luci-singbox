#!/bin/sh
set -eu; cd "$(dirname "$0")/.."
UCODE_BIN="${UCODE_BIN:-ucode}"; UCODE_LIB_DIR="${UCODE_LIB_DIR:-luci-singbox-ui/root/usr/share/singbox-ui/lib}"
command -v "$UCODE_BIN" >/dev/null 2>&1 || { echo "SKIP test_shared_multiplex"; exit 0; }
je() { "$UCODE_BIN" -L "$UCODE_LIB_DIR" -e "$1"; }

# Test 1: disabled → null.
out=$(je 'let m=require("protocols._shared.multiplex"); print(m.emit({multiplex_enabled:"0"})==null?"NULL":"X");')
[ "$out" = "NULL" ] || { echo "FAIL: disabled"; exit 1; }

# Test 2: enabled default protocol smux.
out=$(je 'let m=require("protocols._shared.multiplex"); let r=m.emit({multiplex_enabled:"1"}); print(sprintf("%s|%s",r.enabled,r.protocol));')
[ "$out" = "true|smux" ] || { echo "FAIL: default smux [$out]"; exit 1; }

# Test 3: full advanced.
out=$(je '
    let m=require("protocols._shared.multiplex");
    let r=m.emit({multiplex_enabled:"1",multiplex_protocol:"yamux",multiplex_max_connections:"4",multiplex_min_streams:"4",multiplex_max_streams:"8",multiplex_padding:"1"});
    print(sprintf("%s|%d|%d|%d|%s",r.protocol,r.max_connections,r.min_streams,r.max_streams,r.padding));
')
[ "$out" = "yamux|4|4|8|true" ] || { echo "FAIL: advanced [$out]"; exit 1; }

echo "ALL PASS: test_shared_multiplex"
