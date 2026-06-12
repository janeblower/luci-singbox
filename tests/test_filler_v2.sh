#!/bin/sh
# tests/test_filler_v2.sh — filler v2 primitives.
set -eu
cd "$(dirname "$0")/.."
UCODE_BIN="${UCODE_BIN:-ucode}"
LIB="${UCODE_LIB_DIR:-luci-singbox-ui/root/usr/share/singbox-ui/lib}"
command -v "$UCODE_BIN" >/dev/null 2>&1 || { echo "SKIP test_filler_v2 (ucode missing)"; exit 0; }
je() { "$UCODE_BIN" -L "$LIB" -e "$1"; }
ok() { echo "  PASS: $1"; }
die() { echo "FAIL: $1 [$2]"; exit 1; }

# skip_value drops a matching scalar
out=$(je '
    let f = require("protocols._filler");
    let d = { kind:"outbound", sing_box_type:"x",
        fields:[ { name:"network", type:"enum", json_key:"network", skip_value:"tcp" } ], shared:null };
    print(sprintf("%J", f.build(d, { ".name":"t", network:"tcp" })));
')
[ "$out" = '{ "type": "x", "tag": "t" }' ] || die "skip_value drops tcp" "$out"
ok "skip_value drops matching scalar"

# requires(string): plugin_opts dropped without plugin
out=$(je '
    let f = require("protocols._filler");
    let d = { kind:"outbound", sing_box_type:"x", fields:[
        { name:"plugin", type:"string", json_key:"plugin" },
        { name:"plugin_opts", type:"string", json_key:"plugin_opts", requires:"plugin" },
    ], shared:null };
    print(sprintf("%J", f.build(d, { ".name":"t", plugin_opts:"x" })));
')
[ "$out" = '{ "type": "x", "tag": "t" }' ] || die "requires sibling present" "$out"
ok "requires(string) gates on sibling presence"

# requires({field,value}): packet_encoding only when network==udp
out=$(je '
    let f = require("protocols._filler");
    let d = { kind:"outbound", sing_box_type:"x", fields:[
        { name:"network", type:"enum", json_key:"network", skip_value:"tcp" },
        { name:"packet_encoding", type:"enum", json_key:"packet_encoding", requires:{ field:"network", value:"udp" } },
    ], shared:null };
    print(sprintf("%J", f.build(d, { ".name":"t", network:"tcp", packet_encoding:"xudp" })));
')
[ "$out" = '{ "type": "x", "tag": "t" }' ] || die "requires value match" "$out"
ok "requires({field,value}) gates on sibling value"

# default_when_empty fills a constant but still emits
out=$(je '
    let f = require("protocols._filler");
    let d = { kind:"outbound", sing_box_type:"x", fields:[
        { name:"proto", type:"enum", json_key:"protocol", default_when_empty:"smux", omit_when:"never" },
    ], shared:null };
    print(sprintf("%J", f.build(d, { ".name":"t" })));
')
[ "$out" = '{ "type": "x", "tag": "t", "protocol": "smux" }' ] || die "default_when_empty" "$out"
ok "default_when_empty fills constant"

echo "test_filler_v2: scalar primitives PASS"
