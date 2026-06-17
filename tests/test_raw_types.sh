#!/bin/sh
# tests/test_raw_types.sh — Task 4: raw passthrough outbound/inbound types.
#   type=json      raw_json  -> spliced verbatim (any protocol), tag = section
#   type=sharelink raw_link  -> parsed by sharelink.uc at generate, tag = section
#   protocol=json  raw_json  -> inbound spliced verbatim, tag = section
set -e
. "$(dirname "$0")/lib/sb_helpers.sh"
UCODE_BIN="${UCODE_BIN:-ucode}"
UCODE_LIB_DIR="${UCODE_APP_LIB_DIR:-$PWD/${SB_LIB}}"
command -v "$UCODE_BIN" >/dev/null 2>&1 || { echo "SKIP test_raw_types (ucode missing)"; exit 0; }

je() { "$UCODE_BIN" -L "$UCODE_LIB_DIR" -e "$1"; }
pass() { echo "  PASS: $1"; }
die() { echo "FAIL: $1 (got: $2)"; exit 1; }

# json outbound: a vmess object (no structured descriptor exists for vmess) is
# passed through verbatim; the embedded tag is overridden by the section name.
out=$(je '
    let ob = require("outbound");
    let o = ob.build_constructor_for({".name":"vm","type":"json",
        "raw_json":"{\"type\":\"vmess\",\"server\":\"e.com\",\"server_port\":443,\"uuid\":\"u\",\"tag\":\"EMBEDDED\"}"}, "json");
    print(sprintf("%s|%s|%s", o.type, o.tag, o.server));
')
[ "$out" = "vmess|vm|e.com" ] || die "json outbound passthrough + tag override" "$out"
pass "json outbound: verbatim splice, section tag wins over embedded tag"

# json outbound: invalid JSON is dropped (null), not emitted.
out=$(je '
    let ob = require("outbound");
    let o = ob.build_constructor_for({".name":"b","type":"json","raw_json":"not json"}, "json");
    print(o == null ? "NULL" : "LEAK");
' 2>/dev/null)
[ "$out" = "NULL" ] || die "invalid json dropped" "$out"
pass "json outbound: invalid JSON dropped (null)"

# json outbound: a non-object (JSON array) is rejected.
out=$(je '
    let ob = require("outbound");
    let o = ob.build_constructor_for({".name":"a","type":"json","raw_json":"[1,2,3]"}, "json");
    print(o == null ? "NULL" : "LEAK");
' 2>/dev/null)
[ "$out" = "NULL" ] || die "non-object json dropped" "$out"
pass "json outbound: non-object JSON dropped"

# sharelink outbound: a vless:// link is parsed; section name is the tag.
out=$(je '
    let ob = require("outbound");
    let o = ob.build_constructor_for({".name":"lk","type":"sharelink",
        "raw_link":"vless://11111111-1111-1111-1111-111111111111@host.example:443?security=tls&sni=x#frag"}, "sharelink");
    print(sprintf("%s|%s|%s", o.type, o.tag, o.server));
')
[ "$out" = "vless|lk|host.example" ] || die "sharelink outbound parse + tag" "$out"
pass "sharelink outbound: parsed, section tag applied"

# json inbound: a mixed inbound object spliced verbatim, tag = section name.
out=$(je '
    let inb = require("inbound");
    let i = inb.build_one({".name":"in1","protocol":"json",
        "raw_json":"{\"type\":\"mixed\",\"listen\":\"::\",\"listen_port\":2080}"});
    print(sprintf("%s|%s|%s", i.type, i.tag, i.listen_port));
')
[ "$out" = "mixed|in1|2080" ] || die "json inbound passthrough" "$out"
pass "json inbound: verbatim splice, section tag applied"

echo "OK"
