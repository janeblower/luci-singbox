#!/bin/sh
set -eu; cd "$(dirname "$0")/.."
UCODE_BIN="${UCODE_BIN:-ucode}"; UCODE_LIB_DIR="${UCODE_LIB_DIR:-luci-singbox-ui/root/usr/share/singbox-ui/lib}"
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

# Test 4: every remaining field — covers detour, netns, network_strategy, fallback_delay, reuse_addr, tcp_fast_open, tcp_multi_path, inet4/inet6_bind_address.
out=$(je '
    let d = require("protocols._shared.dial");
    let r = d.emit_outbound({
        inet4_bind_address: "10.0.0.1",
        inet6_bind_address: "fe80::1",
        reuse_addr: "1",
        tcp_fast_open: "1",
        tcp_multi_path: "1",
        network_strategy: "fallback",
        fallback_delay: "300ms",
        detour: "chain_out",
        netns: "/var/run/netns/proxy",
    });
    print(sprintf("%s|%s|%s|%s|%s|%s|%s|%s|%s",
        r.inet4_bind_address, r.inet6_bind_address,
        r.reuse_addr, r.tcp_fast_open, r.tcp_multi_path,
        r.network_strategy, r.fallback_delay, r.detour, r.netns));
')
[ "$out" = "10.0.0.1|fe80::1|true|true|true|fallback|300ms|chain_out|/var/run/netns/proxy" ] \
    || { echo "FAIL: dial full coverage [$out]"; exit 1; }
echo "PASS: emit_outbound full coverage"

echo "ALL PASS: test_shared_dial"
