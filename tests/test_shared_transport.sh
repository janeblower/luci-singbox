#!/bin/sh
# tests/test_shared_transport.sh
set -eu
cd "$(dirname "$0")/.."
UCODE_BIN="${UCODE_BIN:-ucode}"
UCODE_LIB_DIR="${UCODE_LIB_DIR:-luci-singbox-ui/root/usr/share/singbox-ui/lib}"
if ! command -v "$UCODE_BIN" >/dev/null 2>&1; then
    echo "SKIP test_shared_transport (ucode missing)"; exit 0
fi
je() { "$UCODE_BIN" -L "$UCODE_LIB_DIR" -e "$1"; }

# Test 1: transport_type=none → null.
out=$(je '
    let t = require("protocols._shared.transport");
    print(t.emit({ transport_type: "none" }) == null ? "NULL" : "X");
')
[ "$out" = "NULL" ] || { echo "FAIL: none [$out]"; exit 1; }

# Test 2: ws with path + host header.
out=$(je '
    let t = require("protocols._shared.transport");
    let r = t.emit({ transport_type: "ws", transport_path: "/v", transport_host: "cdn.example.com" });
    print(sprintf("%s|%s|%s", r.type, r.path, r.headers.Host));
')
[ "$out" = "ws|/v|cdn.example.com" ] || { echo "FAIL: ws [$out]"; exit 1; }

# Test 3: grpc.
out=$(je '
    let t = require("protocols._shared.transport");
    let r = t.emit({ transport_type: "grpc", transport_service_name: "MyService" });
    print(sprintf("%s|%s", r.type, r.service_name));
')
[ "$out" = "grpc|MyService" ] || { echo "FAIL: grpc [$out]"; exit 1; }

# Test 4: httpupgrade.
out=$(je '
    let t = require("protocols._shared.transport");
    let r = t.emit({ transport_type: "httpupgrade", transport_path: "/u", transport_host_httpupgrade: "h.example" });
    print(sprintf("%s|%s|%s", r.type, r.path, r.host));
')
[ "$out" = "httpupgrade|/u|h.example" ] || { echo "FAIL: httpupgrade [$out]"; exit 1; }

# Test 5: xhttp with mode.
out=$(je '
    let t = require("protocols._shared.transport");
    let r = t.emit({ transport_type: "xhttp", transport_path: "/x", transport_xhttp_mode: "stream-up" });
    print(sprintf("%s|%s|%s", r.type, r.path, r.mode));
')
[ "$out" = "xhttp|/x|stream-up" ] || { echo "FAIL: xhttp [$out]"; exit 1; }

# Test 6: http (hosts array).
out=$(je '
    let t = require("protocols._shared.transport");
    let r = t.emit({ transport_type: "http", transport_hosts: ["a.example","b.example"], transport_path: "/h" });
    print(sprintf("%s|%d|%s|%s|%s", r.type, length(r.host), r.host[0], r.host[1], r.path));
')
[ "$out" = "http|2|a.example|b.example|/h" ] || { echo "FAIL: http [$out]"; exit 1; }

echo "ALL PASS: test_shared_transport"
