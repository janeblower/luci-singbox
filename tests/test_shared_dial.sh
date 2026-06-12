#!/bin/sh
# tests/test_shared_dial.sh — declarative emit_spec path via filler for the
# shared dial block. Dial uses merge mode: its keys fold directly into the
# outbound object (no got.dial sub-key).
set -eu; cd "$(dirname "$0")/.."
UCODE_BIN="${UCODE_BIN:-ucode}"; UCODE_LIB_DIR="${UCODE_LIB_DIR:-luci-singbox-ui/root/usr/share/singbox-ui/lib}"
command -v "$UCODE_BIN" >/dev/null 2>&1 || { echo "SKIP test_shared_dial"; exit 0; }
je() { "$UCODE_BIN" -L "$UCODE_LIB_DIR" -e "$1"; }

# Helper: build an outbound via filler with dial shared block.
# Dial is merge-mode: keys fold into the top-level object alongside type/tag.
# We strip the fixed type/tag/keys count to isolate only dial fields.

# Test 1: no fields set → merged object adds nothing (only type+tag present).
out=$(je '
    let f = require("protocols._filler");
    let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ dial:true } },
        { ".name":"t" }
    );
    // type and tag are always present; dial should add nothing else
    let extra = length(keys(got)) - 2;
    print(extra);
')
[ "$out" = "0" ] || { echo "FAIL: empty — expected 0 extra keys, got [$out]"; exit 1; }

# Test 2: bind_interface only folds into top-level.
out=$(je '
    let f = require("protocols._filler");
    let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ dial:true } },
        { ".name":"t", bind_interface:"wan" }
    );
    print(got.bind_interface);
')
[ "$out" = "wan" ] || { echo "FAIL: bind_interface [$out]"; exit 1; }

# Test 3: advanced — routing_mark + connect_timeout + udp_fragment.
out=$(je '
    let f = require("protocols._filler");
    let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ dial:true } },
        { ".name":"t", bind_interface:"wan", routing_mark:"100",
          connect_timeout:"5s", udp_fragment:"1", domain_strategy:"prefer_ipv4" }
    );
    print(sprintf("%s|%d|%s|%s|%s",
        got.bind_interface, got.routing_mark, got.connect_timeout,
        got.udp_fragment, got.domain_strategy));
')
[ "$out" = "wan|100|5s|true|prefer_ipv4" ] || { echo "FAIL: advanced [$out]"; exit 1; }

# Test 4: every remaining field — covers detour, netns, network_strategy, fallback_delay, reuse_addr, tcp_fast_open, tcp_multi_path, inet4/inet6_bind_address.
out=$(je '
    let f = require("protocols._filler");
    let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ dial:true } },
        { ".name":"t",
          inet4_bind_address:"10.0.0.1",
          inet6_bind_address:"fe80::1",
          reuse_addr:"1",
          tcp_fast_open:"1",
          tcp_multi_path:"1",
          network_strategy:"fallback",
          fallback_delay:"300ms",
          detour:"chain_out",
          netns:"/var/run/netns/proxy" }
    );
    print(sprintf("%s|%s|%s|%s|%s|%s|%s|%s|%s",
        got.inet4_bind_address, got.inet6_bind_address,
        got.reuse_addr, got.tcp_fast_open, got.tcp_multi_path,
        got.network_strategy, got.fallback_delay, got.detour, got.netns));
')
[ "$out" = "10.0.0.1|fe80::1|true|true|true|fallback|300ms|chain_out|/var/run/netns/proxy" ] \
    || { echo "FAIL: dial full coverage [$out]"; exit 1; }
echo "PASS: dial full coverage"

# Test 5: dial reference fields expose dynamic selector sources so the UI
# renders dropdowns (detour→existing outbounds, bind_interface→logical
# interfaces) instead of free-text tags the user has to type by hand.
out=$(je '
    let d = require("protocols._shared.dial");
    let dyn = {};
    for (let f in d.fields) if (f.dynamic) dyn[f.name] = f.dynamic;
    print(sprintf("%s|%s", dyn.detour, dyn.bind_interface));
')
[ "$out" = "outbounds|interfaces" ] || { echo "FAIL: dial dynamic sources [$out]"; exit 1; }
echo "PASS: detour/bind_interface dynamic selector sources"

echo "ALL PASS: test_shared_dial"
