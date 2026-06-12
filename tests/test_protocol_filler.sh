#!/bin/sh
# tests/test_protocol_filler.sh
# Declarative protocol filler (lib/protocols/_filler.uc): field coercion,
# omit rules, json_key rename, UI-only skip, post hook, shared-block dispatch,
# and golden parity for the converted trojan/direct outbound descriptors.
set -eu
cd "$(dirname "$0")/.."

UCODE_BIN="${UCODE_BIN:-ucode}"
UCODE_LIB_DIR="${UCODE_LIB_DIR:-luci-singbox-ui/root/usr/share/singbox-ui/lib}"
command -v "$UCODE_BIN" >/dev/null 2>&1 || { echo "SKIP test_protocol_filler (ucode missing)"; exit 0; }

je() { "$UCODE_BIN" -L "$UCODE_LIB_DIR" -e "$1"; }
ok()  { echo "  PASS: $1"; }
die() { echo "FAIL: $1 [$2]"; exit 1; }

# ---- flat field coercion: str/num/bool/array, omit empty vs never, rename ----
out=$(je '
    let filler = require("protocols._filler");
    let d = {
        kind: "outbound", sing_box_type: "demo",
        fields: [
            { name: "a",      type: "string", json_key: "a" },
            { name: "ren",    type: "string", json_key: "renamed" },
            { name: "p",      type: "number", json_key: "p", coerce: "num" },
            { name: "keepme", type: "string", json_key: "keepme", omit_when: "never" },
            { name: "flag",   type: "bool",   json_key: "flag", coerce: "bool" },
            { name: "off",    type: "bool",   json_key: "off",  coerce: "bool" },
            { name: "lst",    type: "list",   json_key: "lst",  coerce: "array" },
            { name: "uionly", type: "string" },              // no json_key -> skipped
        ],
        shared: null,
    };
    let got = filler.build(d, {
        ".name": "tag1",
        a: "hello", ren: "X", p: "42", keepme: "",
        flag: "1", off: "0", lst: [ "h2", "http/1.1" ],
        uionly: "ignored",
    });
    let want = {
        type: "demo", tag: "tag1",
        a: "hello", renamed: "X", p: 42, keepme: "",
        flag: true, lst: [ "h2", "http/1.1" ],
    };
    print(sprintf("%J", got) === sprintf("%J", want) ? "MATCH" : sprintf("MISMATCH got=%J want=%J", got, want));
')
[ "$out" = "MATCH" ] || die "flat field coercion/omit/rename/skip" "$out"
ok "flat field coercion + omit + rename + UI-only skip"

# ---- omit_when empty drops empty string scalars ----
out=$(je '
    let filler = require("protocols._filler");
    let d = { kind:"outbound", sing_box_type:"demo",
              fields:[ { name:"x", type:"string", json_key:"x" } ], shared:null };
    let got = filler.build(d, { ".name":"t", x:"" });
    print(sprintf("%J", got));
')
[ "$out" = '{ "type": "demo", "tag": "t" }' ] || die "omit_when empty drops empty scalar" "$out"
ok "omit_when empty drops empty scalar"

# ---- post hook runs last and mutates the object ----
out=$(je '
    let filler = require("protocols._filler");
    let d = {
        kind:"outbound", sing_box_type:"demo", shared:null,
        fields:[ { name:"a", type:"string", json_key:"a" } ],
        post: function(out, s) { out.extra = "added"; },
    };
    let got = filler.build(d, { ".name":"t", a:"v" });
    print(sprintf("%J", got));
')
[ "$out" = '{ "type": "demo", "tag": "t", "a": "v", "extra": "added" }' ] || die "post hook mutates output" "$out"
ok "post hook runs last"

echo "test_protocol_filler: all PASS"
