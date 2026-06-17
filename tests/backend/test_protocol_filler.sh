#!/bin/sh
# tests/test_protocol_filler.sh
# Declarative protocol filler (lib/protocols/_filler.uc): field coercion,
# omit rules, json_key rename, UI-only skip, post hook, shared-block dispatch,
# and golden parity for the converted trojan/direct outbound descriptors.
set -eu
. "$(dirname "$0")/../lib/sb_helpers.sh"
cd "$(dirname "$0")/../.."

UCODE_BIN="${UCODE_BIN:-ucode}"
UCODE_LIB_DIR="${UCODE_LIB_DIR:-${SB_LIB}}"
command -v "$UCODE_BIN" >/dev/null 2>&1 || { echo "SKIP test_protocol_filler (ucode missing)"; exit 0; }

je() { "$UCODE_BIN" -L "$UCODE_LIB_DIR" -e "$1"; }
ok()  { echo "  PASS: $1"; }
die() { echo "FAIL: $1 [$2]"; exit 1; }

# ---- flat field coercion: str/num/bool/array, omit empty vs never, rename ----
out=$(je '
    let filler = require("builder._filler");
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
    let filler = require("builder._filler");
    let d = { kind:"outbound", sing_box_type:"demo",
              fields:[ { name:"x", type:"string", json_key:"x" } ], shared:null };
    let got = filler.build(d, { ".name":"t", x:"" });
    print(sprintf("%J", got));
')
[ "$out" = '{ "type": "demo", "tag": "t" }' ] || die "omit_when empty drops empty scalar" "$out"
ok "omit_when empty drops empty scalar"

# ---- post hook runs last and mutates the object ----
out=$(je '
    let filler = require("builder._filler");
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

# ---- shared dispatch: tls merges under out.tls when enabled ----
out=$(je '
    let filler = require("builder._filler");
    let d = { kind:"outbound", sing_box_type:"vless", fields:[], shared:{ tls:{} } };
    let got = filler.build(d, { ".name":"v1", tls_enabled:"1", tls_server_name:"sni.example" });
    print((got.tls != null && got.tls.enabled === true && got.tls.server_name === "sni.example") ? "OK" : sprintf("BAD %J", got));
')
[ "$out" = "OK" ] || die "shared tls merges when enabled" "$out"
ok "shared tls merges under out.tls"

# ---- shared dispatch: tls disabled -> no tls key ----
out=$(je '
    let filler = require("builder._filler");
    let d = { kind:"outbound", sing_box_type:"vless", fields:[], shared:{ tls:{} } };
    let got = filler.build(d, { ".name":"v1" });
    print(got.tls == null ? "OK" : sprintf("BAD %J", got));
')
[ "$out" = "OK" ] || die "shared tls omitted when disabled" "$out"
ok "shared tls omitted when disabled"

# ---- shared dispatch: tls force_enabled opts passed through ----
out=$(je '
    let filler = require("builder._filler");
    let d = { kind:"outbound", sing_box_type:"hysteria2", fields:[], shared:{ tls:{ force_enabled:true } } };
    let got = filler.build(d, { ".name":"h1" });   // tls_enabled NOT set
    print((got.tls != null && got.tls.enabled === true) ? "OK" : sprintf("BAD %J", got));
')
[ "$out" = "OK" ] || die "shared tls force_enabled opts pass through" "$out"
ok "shared tls force_enabled passes opts"

# ---- shared dispatch: dial merge adds nothing on empty section ----
out=$(je '
    let filler = require("builder._filler");
    let d = { kind:"outbound", sing_box_type:"direct", fields:[], shared:{ dial:true } };
    let got = filler.build(d, { ".name":"d1" });
    print(sprintf("%J", got));
')
[ "$out" = '{ "type": "direct", "tag": "d1" }' ] || die "shared dial empty adds nothing" "$out"
ok "shared dial merge no-op on empty section"

# ---- golden parity: trojan outbound via the production dispatcher ----
out=$(je '
    let ob = require("outbound");
    let got = ob.build_constructor_for(
        { ".name":"trj1", server:"example.com", server_port:"443", server_password:"secret" },
        "trojan");
    let want = { type:"trojan", tag:"trj1", server:"example.com", server_port:443, password:"secret" };
    print(sprintf("%J", got) === sprintf("%J", want) ? "MATCH" : sprintf("MISMATCH got=%J want=%J", got, want));
')
[ "$out" = "MATCH" ] || die "trojan outbound golden parity" "$out"
ok "trojan outbound golden parity"

# ---- golden parity: direct outbound via the production dispatcher ----
out=$(je '
    let ob = require("outbound");
    let got = ob.build_constructor_for(
        { ".name":"dir1", override_address:"1.1.1.1", override_port:"5353", proxy_protocol:"2" },
        "direct");
    let want = { type:"direct", tag:"dir1", override_address:"1.1.1.1", override_port:5353, proxy_protocol:2 };
    print(sprintf("%J", got) === sprintf("%J", want) ? "MATCH" : sprintf("MISMATCH got=%J want=%J", got, want));
')
[ "$out" = "MATCH" ] || die "direct outbound golden parity" "$out"
ok "direct outbound golden parity"

# ---- golden parity: direct outbound with all override fields empty ----
out=$(je '
    let ob = require("outbound");
    let got = ob.build_constructor_for({ ".name":"dir2" }, "direct");
    print(sprintf("%J", got));
')
[ "$out" = '{ "type": "direct", "tag": "dir2" }' ] || die "direct outbound empty section" "$out"
ok "direct outbound empty section omits all overrides"

# ---- registry: a descriptor with fields but no emit registers OK ----
out=$(je '
    let reg = require("builder.protocols.registry");
    let threw = false;
    try {
        reg.register({ kind:"outbound", type:"declonly_t3", sing_box_type:"x",
                       fields:[ { name:"f", type:"string", tab:"basic", json_key:"f" } ] });
    } catch (e) { threw = true; }
    print((!threw && reg.get("outbound","declonly_t3") != null) ? "OK" : "BAD");
')
[ "$out" = "OK" ] || die "registry accepts declarative (no emit) descriptor" "$out"
ok "registry accepts emit-less declarative descriptor"

# ---- registry: a descriptor with neither emit nor fields is rejected ----
out=$(je '
    let reg = require("builder.protocols.registry");
    let threw = false;
    try { reg.register({ kind:"outbound", type:"empty_t3", sing_box_type:"x" }); }
    catch (e) { threw = true; }
    print(threw ? "THREW" : "NOTHREW");
')
[ "$out" = "THREW" ] || die "registry rejects descriptor with neither emit nor fields" "$out"
ok "registry rejects emit-less + fields-less descriptor"

# ---- registry: emit-less descriptor with an EMPTY fields[] is rejected ----
out=$(je '
    let reg = require("builder.protocols.registry");
    let threw = false;
    try { reg.register({ kind:"outbound", type:"emptyfields_t3", sing_box_type:"x", fields:[] }); }
    catch (e) { threw = true; }
    print(threw ? "THREW" : "NOTHREW");
')
[ "$out" = "THREW" ] || die "registry rejects emit-less descriptor with empty fields[]" "$out"
ok "registry rejects emit-less + empty-fields descriptor"

# ---- registry: a non-function post is rejected ----
out=$(je '
    let reg = require("builder.protocols.registry");
    let threw = false;
    try {
        reg.register({ kind:"outbound", type:"badpost_t3", sing_box_type:"x",
                       fields:[ { name:"f", type:"string", tab:"basic" } ], post: 7 });
    } catch (e) { threw = true; }
    print(threw ? "THREW" : "NOTHREW");
')
[ "$out" = "THREW" ] || die "registry rejects non-function post" "$out"
ok "registry rejects non-function post"

# ---- validate_field: unknown coerce is rejected ----
out=$(je '
    let reg = require("builder.protocols.registry");
    let threw = false;
    try {
        reg.register({ kind:"outbound", type:"badcoerce_t3", sing_box_type:"x",
                       fields:[ { name:"f", type:"string", tab:"basic", json_key:"f", coerce:"bogus" } ] });
    } catch (e) { threw = true; }
    print(threw ? "THREW" : "NOTHREW");
')
[ "$out" = "THREW" ] || die "validate_field rejects unknown coerce" "$out"
ok "validate_field rejects unknown coerce"

echo "test_protocol_filler: all PASS"
