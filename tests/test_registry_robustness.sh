#!/bin/sh
# tests/test_registry_robustness.sh
# S4-3 try_register: a malformed descriptor logs+skips instead of aborting.
# S4-4 _shared_module: a broken shared module surfaces a warn(), not silence.
# S4-5 validate_field: enum/values/default consistency is enforced.
set -eu
. "$(dirname "$0")/lib/sb_helpers.sh"
cd "$(dirname "$0")/.."

UCODE_BIN="${UCODE_BIN:-ucode}"
UCODE_LIB_DIR="${UCODE_LIB_DIR:-${SB_LIB}}"
command -v "$UCODE_BIN" >/dev/null 2>&1 || { echo "SKIP test_registry_robustness (ucode missing)"; exit 0; }

# je() captures STDOUT only (mirrors tests/test_share_link_hy2.sh:7). Do NOT add
# 2>&1 here: try_register() (S4-3) calls warn() on the skip path, and the S4-5
# assertions exact-match "REJECTED"/"ACCEPTED" — mixing warn() stderr into $out
# would break those exact-match checks. The ONE case that needs stderr (S4-4)
# captures it explicitly on its own ucode invocation (see the S44_DIR block),
# not through je().
je() { "$UCODE_BIN" -L "$UCODE_LIB_DIR" -e "$1"; }
pass=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
die() { echo "FAIL: $1 [$2]"; exit 1; }

# ---- S4-3: try_register swallows a malformed descriptor (no throw) ----
out=$(je '
    let reg = require("builder.protocols.registry");
    let threw = false;
    try {
        reg.try_register({
            kind: "outbound", type: "broken_s43", sing_box_type: "x",
            fields: [ { name: "f", type: "string" } ],   // missing tab -> would assert
            emit: function(s) { return {}; },
        });
    } catch (e) { threw = true; }
    // must NOT throw, and must NOT have registered the broken descriptor
    print(!threw && reg.get("outbound","broken_s43") == null ? "SKIPPED" : "BAD");
')
[ "$out" = "SKIPPED" ] || die "S4-3 try_register must skip malformed descriptor without throwing" "$out"
ok "S4-3 try_register skips malformed descriptor"

# ---- S4-3: plain register() still throws (contract relied on by other tests) ----
out=$(je '
    let reg = require("builder.protocols.registry");
    let threw = false;
    try {
        reg.register({ kind:"outbound", type:"strict_s43", sing_box_type:"x",
                       fields:[{ name:"f", type:"string" }], emit:function(s){return {};} });
    } catch (e) { threw = true; }
    print(threw ? "THREW" : "NOTHREW");
')
[ "$out" = "THREW" ] || die "S4-3 register() must still throw on malformed descriptor" "$out"
ok "S4-3 register() still strict"

# ---- S4-4: a broken shared module surfaces a warn() on stderr ----
# Create a throwaway lib tree with a syntactically broken _shared module and a
# descriptor that references it, then materialize and capture stderr.
S44_DIR=$(mktemp -d)
trap 'rm -rf "$S44_DIR"' EXIT
mkdir -p "$S44_DIR/builder/protocols" "$S44_DIR/builder/_shared"
# Copy the registry + helpers so require() resolves inside the throwaway tree.
cp "$UCODE_LIB_DIR/builder/protocols/registry.uc" "$S44_DIR/builder/protocols/registry.uc"
cp "$UCODE_LIB_DIR/helpers.uc" "$S44_DIR/helpers.uc"
# A shared module that throws on load (references an undefined symbol).
printf '%s\n' 'this_symbol_is_not_defined();' > "$S44_DIR/builder/_shared/boom.uc"
# Teach the registry's KNOWN_SHARED about "boom" is not needed: _shared_fields
# only loads modules named in d.shared, and validate_shared would reject an
# unknown key. So we register with a KNOWN key whose module we shadow: shadow
# multiplex.uc with a broken file.
printf '%s\n' 'this_symbol_is_not_defined();' > "$S44_DIR/builder/_shared/multiplex.uc"
rm -f "$S44_DIR/builder/_shared/boom.uc"
s44=$("$UCODE_BIN" -L "$S44_DIR" -e '
    let reg = require("builder.protocols.registry");
    reg.register({
        kind: "outbound", type: "s44", sing_box_type: "x",
        shared: { multiplex: {} },
        fields: [ { name: "f", type: "string", tab: "basic" } ],
        emit: function(s) { return {}; },
    });
    reg.materialize("outbound", "s44");
    print("DONE");
' 2>&1)
case "$s44" in
    *"DONE"*) : ;;   # materialize must still complete (returns null module -> skip block)
    *) die "S4-4 materialize crashed instead of skipping broken shared module" "$s44" ;;
esac
case "$s44" in
    *registry:*shared*|*multiplex*|*"shared module"*) ok "S4-4 broken shared module warns" ;;
    *) die "S4-4 broken shared module produced no warning" "$s44" ;;
esac

# ---- S4-5: enum field without values[] is rejected ----
out=$(je '
    let reg = require("builder.protocols.registry");
    let threw = false;
    try {
        reg.register({ kind:"outbound", type:"s45a", sing_box_type:"x",
            fields:[{ name:"e", type:"enum", tab:"basic" }],   // enum w/o values
            emit:function(s){return {};} });
    } catch (e) { threw = true; }
    print(threw ? "REJECTED" : "ACCEPTED");
')
[ "$out" = "REJECTED" ] || die "S4-5 enum without values[] must be rejected" "$out"
ok "S4-5 enum without values rejected"

# ---- S4-5: non-enum field carrying values[] is rejected ----
out=$(je '
    let reg = require("builder.protocols.registry");
    let threw = false;
    try {
        reg.register({ kind:"outbound", type:"s45b", sing_box_type:"x",
            fields:[{ name:"n", type:"number", tab:"basic", values:["","1","2"] }],
            emit:function(s){return {};} });
    } catch (e) { threw = true; }
    print(threw ? "REJECTED" : "ACCEPTED");
')
[ "$out" = "REJECTED" ] || die "S4-5 number with values[] must be rejected" "$out"
ok "S4-5 number+values rejected"

# ---- S4-5: enum default not in values[] is rejected ----
out=$(je '
    let reg = require("builder.protocols.registry");
    let threw = false;
    try {
        reg.register({ kind:"outbound", type:"s45c", sing_box_type:"x",
            fields:[{ name:"e", type:"enum", tab:"basic",
                      values:["a","b"], default:"c" }],
            emit:function(s){return {};} });
    } catch (e) { threw = true; }
    print(threw ? "REJECTED" : "ACCEPTED");
')
[ "$out" = "REJECTED" ] || die "S4-5 enum default outside values[] must be rejected" "$out"
ok "S4-5 enum default outside values rejected"

# ---- S4-5: valid enum with default in values[] still accepted ----
out=$(je '
    let reg = require("builder.protocols.registry");
    let threw = false;
    try {
        reg.register({ kind:"outbound", type:"s45d", sing_box_type:"x",
            fields:[{ name:"e", type:"enum", tab:"basic",
                      values:["","a","b"], default:"a" }],
            emit:function(s){return {};} });
    } catch (e) { threw = true; }
    print(threw ? "REJECTED" : "ACCEPTED");
')
[ "$out" = "ACCEPTED" ] || die "S4-5 valid enum must still be accepted" "$out"
ok "S4-5 valid enum accepted"

# ---- combobox: list/string MAY carry values[] (datalist suggestions) ----
out=$(je '
    let reg = require("builder.protocols.registry");
    let threw = false;
    try {
        reg.register({ kind:"outbound", type:"s45e", sing_box_type:"x",
            fields:[{ name:"l", type:"list", tab:"basic", values:["a","b"] }],
            emit:function(s){return {};} });
    } catch (e) { threw = true; }
    print(threw ? "REJECTED" : "ACCEPTED");
')
[ "$out" = "ACCEPTED" ] || die "list+values must be accepted (combobox suggestions)" "$out"
ok "list+values accepted"

out=$(je '
    let reg = require("builder.protocols.registry");
    let threw = false;
    try {
        reg.register({ kind:"outbound", type:"s45f", sing_box_type:"x",
            fields:[{ name:"st", type:"string", tab:"basic", values:["a","b"] }],
            emit:function(s){return {};} });
    } catch (e) { threw = true; }
    print(threw ? "REJECTED" : "ACCEPTED");
')
[ "$out" = "ACCEPTED" ] || die "string+values must be accepted (combobox suggestions)" "$out"
ok "string+values accepted"

# ---- dynamic selector source: unknown discriminator rejected, known accepted ----
out=$(je '
    let reg = require("builder.protocols.registry");
    let threw = false;
    try {
        reg.register({ kind:"outbound", type:"s45g", sing_box_type:"x",
            fields:[{ name:"d", type:"string", tab:"basic", dynamic:"bogus" }],
            emit:function(s){return {};} });
    } catch (e) { threw = true; }
    print(threw ? "REJECTED" : "ACCEPTED");
')
[ "$out" = "REJECTED" ] || die "unknown dynamic source must be rejected" "$out"
ok "unknown dynamic source rejected"

out=$(je '
    let reg = require("builder.protocols.registry");
    let threw = false;
    try {
        reg.register({ kind:"outbound", type:"s45h", sing_box_type:"x",
            fields:[{ name:"d", type:"string", tab:"basic", dynamic:"outbounds" }],
            emit:function(s){return {};} });
    } catch (e) { threw = true; }
    print(threw ? "REJECTED" : "ACCEPTED");
')
[ "$out" = "ACCEPTED" ] || die "known dynamic source must be accepted" "$out"
ok "known dynamic source accepted"

# ---- BLD-8: requires.field referencing an unknown sibling is rejected ----
out=$(je '
    let reg = require("builder.protocols.registry");
    let threw = false;
    try {
        reg.register({ kind:"outbound", type:"bld8a", sing_box_type:"x",
            fields:[ { name:"network", type:"string", tab:"basic", json_key:"network" },
                     { name:"pe", type:"string", tab:"basic", json_key:"packet_encoding",
                       requires:{ field:"netwrk", value:"udp" } } ],   // typo
            emit:function(s){return {};} });
    } catch (e) { threw = true; }
    print(threw ? "REJECTED" : "ACCEPTED");
')
[ "$out" = "REJECTED" ] || die "BLD-8 typod requires.field must be rejected" "$out"
ok "BLD-8 requires.field typo rejected"

# ---- BLD-8: a valid sibling requires.field is accepted ----
out=$(je '
    let reg = require("builder.protocols.registry");
    let threw = false;
    try {
        reg.register({ kind:"outbound", type:"bld8b", sing_box_type:"x",
            fields:[ { name:"network", type:"string", tab:"basic", json_key:"network" },
                     { name:"pe", type:"string", tab:"basic", json_key:"packet_encoding",
                       requires:{ field:"network", value:"udp" } } ],
            emit:function(s){return {};} });
    } catch (e) { threw = true; }
    print(threw ? "REJECTED" : "ACCEPTED");
')
[ "$out" = "ACCEPTED" ] || die "BLD-8 valid requires.field must be accepted" "$out"
ok "BLD-8 valid requires.field accepted"

# ---- BLD-8: parent_enabled referencing a SHARED-block field is accepted ----
out=$(je '
    let reg = require("builder.protocols.registry");
    let threw = false;
    try {
        reg.register({ kind:"outbound", type:"bld8c", sing_box_type:"x",
            shared:{ tls:{} },
            fields:[ { name:"foo", type:"string", tab:"tls", json_key:"foo",
                       parent_enabled:"tls_enabled" } ],   // tls_enabled comes from shared tls
            emit:function(s){return {};} });
    } catch (e) { threw = true; }
    print(threw ? "REJECTED" : "ACCEPTED");
')
[ "$out" = "ACCEPTED" ] || die "BLD-8 parent_enabled to shared field must be accepted" "$out"
ok "BLD-8 parent_enabled to shared field accepted"

# ---- BLD-8: a non-scalar default_when_empty is rejected ----
out=$(je '
    let reg = require("builder.protocols.registry");
    let threw = false;
    try {
        reg.register({ kind:"outbound", type:"bld8d", sing_box_type:"x",
            fields:[ { name:"f", type:"string", tab:"basic", json_key:"f",
                       default_when_empty:["bad"] } ],   // array, not scalar
            emit:function(s){return {};} });
    } catch (e) { threw = true; }
    print(threw ? "REJECTED" : "ACCEPTED");
')
[ "$out" = "REJECTED" ] || die "BLD-8 non-scalar default_when_empty must be rejected" "$out"
ok "BLD-8 non-scalar default_when_empty rejected"

echo "ALL PASS: test_registry_robustness ($pass checks)"
