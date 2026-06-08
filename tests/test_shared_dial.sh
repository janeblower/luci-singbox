#!/bin/sh
set -eu; cd "$(dirname "$0")/.."
UCODE_BIN="${UCODE_BIN:-ucode}"; UCODE_LIB_DIR="${UCODE_LIB_DIR:-luci-app-singbox-ui/root/usr/share/singbox-ui/lib}"
command -v "$UCODE_BIN" >/dev/null 2>&1 || { echo "SKIP test_shared_dial"; exit 0; }
je() { "$UCODE_BIN" -L "$UCODE_LIB_DIR" -e "$1"; }

# Test 1: no fields set → empty object.
out=$(je 'let d=require("protocols._shared.dial"); let r=d.emit_outbound({}); print(length(keys(r)));')
[ "$out" = "0" ] || { echo "FAIL: empty"; exit 1; }

# Test 2: bind_interface only.
out=$(je 'let d=require("protocols._shared.dial"); let r=d.emit_outbound({bind_interface:"wan"}); print(r.bind_interface);')
[ "$out" = "wan" ] || { echo "FAIL: bind_interface"; exit 1; }

# Test 3: advanced — routing_mark + connect_timeout + udp_fragment.
out=$(je '
    let d=require("protocols._shared.dial");
    let r=d.emit_outbound({bind_interface:"wan",routing_mark:"100",connect_timeout:"5s",udp_fragment:"1",domain_strategy:"prefer_ipv4"});
    print(sprintf("%s|%d|%s|%s|%s",r.bind_interface,r.routing_mark,r.connect_timeout,r.udp_fragment,r.domain_strategy));
')
[ "$out" = "wan|100|5s|true|prefer_ipv4" ] || { echo "FAIL: advanced [$out]"; exit 1; }

echo "ALL PASS: test_shared_dial"
