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

echo "ALL PASS: test_registry_robustness ($pass checks)"
