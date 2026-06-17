#!/bin/sh
# tests/test_shared_transport.sh — declarative emit_spec path via filler for
# the shared transport block.
set -eu
. "$(dirname "$0")/lib/sb_helpers.sh"
cd "$(dirname "$0")/.."
UCODE_BIN="${UCODE_BIN:-ucode}"
UCODE_LIB_DIR="${UCODE_LIB_DIR:-${SB_LIB}}"
if ! command -v "$UCODE_BIN" >/dev/null 2>&1; then
    echo "SKIP test_shared_transport (ucode missing)"; exit 0
fi
je() { "$UCODE_BIN" -L "$UCODE_LIB_DIR" -e "$1"; }

# Helper: build transport block via filler
# f.build({kind:"outbound",sing_box_type:"x",fields:[],shared:{transport:true}}, s)
# → got.transport (or null when type=none)

# Test 1: transport_type=none → no transport key.
out=$(je '
    let f = require("builder._filler");
    let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ transport:true } },
        { ".name":"t", transport_type:"none" }
    );
    print(got.transport == null ? "NULL" : "X");
')
[ "$out" = "NULL" ] || { echo "FAIL: none [$out]"; exit 1; }

# Test 2: ws with path + host header.
out=$(je '
    let f = require("builder._filler");
    let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ transport:true } },
        { ".name":"t", transport_type:"ws", transport_path:"/v", transport_host:"cdn.example.com" }
    );
    print(sprintf("%s|%s|%s", got.transport.type, got.transport.path, got.transport.headers.Host));
')
[ "$out" = "ws|/v|cdn.example.com" ] || { echo "FAIL: ws [$out]"; exit 1; }

# Test 3: grpc.
out=$(je '
    let f = require("builder._filler");
    let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ transport:true } },
        { ".name":"t", transport_type:"grpc", transport_service_name:"MyService" }
    );
    print(sprintf("%s|%s", got.transport.type, got.transport.service_name));
')
[ "$out" = "grpc|MyService" ] || { echo "FAIL: grpc [$out]"; exit 1; }

# Test 4: httpupgrade.
out=$(je '
    let f = require("builder._filler");
    let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ transport:true } },
        { ".name":"t", transport_type:"httpupgrade", transport_path:"/u",
          transport_host_httpupgrade:"h.example" }
    );
    print(sprintf("%s|%s|%s", got.transport.type, got.transport.path, got.transport.host));
')
[ "$out" = "httpupgrade|/u|h.example" ] || { echo "FAIL: httpupgrade [$out]"; exit 1; }

# Test 5: xhttp with mode.
out=$(je '
    let f = require("builder._filler");
    let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ transport:true } },
        { ".name":"t", transport_type:"xhttp", transport_path:"/x",
          transport_xhttp_mode:"stream-up" }
    );
    print(sprintf("%s|%s|%s", got.transport.type, got.transport.path, got.transport.mode));
')
[ "$out" = "xhttp|/x|stream-up" ] || { echo "FAIL: xhttp [$out]"; exit 1; }

# Test 6: http (hosts array).
out=$(je '
    let f = require("builder._filler");
    let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ transport:true } },
        { ".name":"t", transport_type:"http",
          transport_hosts:["a.example","b.example"], transport_path:"/h" }
    );
    print(sprintf("%s|%d|%s|%s|%s",
        got.transport.type, length(got.transport.host),
        got.transport.host[0], got.transport.host[1], got.transport.path));
')
[ "$out" = "http|2|a.example|b.example|/h" ] || { echo "FAIL: http [$out]"; exit 1; }

echo "ALL PASS: test_shared_transport"
