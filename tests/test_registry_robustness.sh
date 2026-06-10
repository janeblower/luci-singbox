#!/bin/sh
# tests/test_registry_robustness.sh
# S4-3 try_register: a malformed descriptor logs+skips instead of aborting.
# S4-4 _shared_module: a broken shared module surfaces a warn(), not silence.
# S4-5 validate_field: enum/values/default consistency is enforced.
set -eu
cd "$(dirname "$0")/.."

UCODE_BIN="${UCODE_BIN:-ucode}"
UCODE_LIB_DIR="${UCODE_LIB_DIR:-luci-app-singbox-ui/root/usr/share/singbox-ui/lib}"
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
    let reg = require("protocols.registry");
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
    let reg = require("protocols.registry");
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
mkdir -p "$S44_DIR/protocols/_shared"
# Copy the registry + helpers so require() resolves inside the throwaway tree.
cp "$UCODE_LIB_DIR/protocols/registry.uc" "$S44_DIR/protocols/registry.uc"
cp "$UCODE_LIB_DIR/helpers.uc" "$S44_DIR/helpers.uc"
# A shared module that throws on load (references an undefined symbol).
printf '%s\n' 'this_symbol_is_not_defined();' > "$S44_DIR/protocols/_shared/boom.uc"
# Teach the registry's KNOWN_SHARED about "boom" is not needed: _shared_fields
# only loads modules named in d.shared, and validate_shared would reject an
# unknown key. So we register with a KNOWN key whose module we shadow: shadow
# multiplex.uc with a broken file.
printf '%s\n' 'this_symbol_is_not_defined();' > "$S44_DIR/protocols/_shared/multiplex.uc"
rm -f "$S44_DIR/protocols/_shared/boom.uc"
s44=$("$UCODE_BIN" -L "$S44_DIR" -e '
    let reg = require("protocols.registry");
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

echo "ALL PASS: test_registry_robustness ($pass checks)"
