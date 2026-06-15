#!/bin/sh
# tests/test_descriptor_materialize.sh
# Validates registry.materialize(kind, type): field union (protocol + shared
# blocks gated by flags), per-tab _show_advanced_<tab> injection, and
# rejection of malformed descriptors (missing tab, unknown shared key).
# NOTE: _show_advanced_<tab> injection is now scoped to dns/route kinds only
# (inbound/outbound show all fields, Bug 4), so the injection tests register
# under kind "dns". The outbound "no toggle" side is covered by
# tests/test_advanced_scope.sh.
set -eu
cd "$(dirname "$0")/.."

UCODE_BIN="${UCODE_BIN:-ucode}"
UCODE_LIB_DIR="${UCODE_LIB_DIR:-luci-singbox-ui/root/usr/share/singbox-ui/lib}"

if ! command -v "$UCODE_BIN" >/dev/null 2>&1; then
    echo "SKIP test_descriptor_materialize (ucode missing)"; exit 0
fi

# Test 1: register + materialize on a minimal descriptor with one shared block.
# shellcheck disable=SC2086
out=$("$UCODE_BIN" -L "$UCODE_LIB_DIR" -e '
    let reg = require("builder.protocols.registry");
    reg.register({
        kind: "dns", type: "demo", sing_box_type: "demo",
        shared: { tls: { enabled_field: "tls_enabled" } },
        fields: [
            { name: "server", type: "string", tab: "basic", required: true },
        ],
        emit: function(s) { return { type: "demo" }; },
    });
    let m = reg.materialize("dns", "demo");
    print(sprintf("tabs=%s fields=%d", join(",", m.tabs), length(m.fields)));
')
case "$out" in
    "tabs=tls,basic fields=27") echo "PASS: materialize union ($out)" ;;
    *) echo "FAIL: materialize union [$out]"; exit 1 ;;
esac

# Test 2: descriptor with missing tab on a field is rejected.
# shellcheck disable=SC2086
out=$("$UCODE_BIN" -L "$UCODE_LIB_DIR" -e '
    let reg = require("builder.protocols.registry");
    try {
        reg.register({
            kind: "outbound", type: "badtab", sing_box_type: "x",
            fields: [ { name: "foo", type: "string" } ],
            emit: function(s) { return {}; },
        });
        print("REGISTERED");
    } catch (e) { print("REJECTED: " + e); }
' 2>&1)
case "$out" in
    "REJECTED:"*) echo "PASS: missing tab rejected" ;;
    *) echo "FAIL: missing-tab not rejected [$out]"; exit 1 ;;
esac

# Test 3: unknown shared key rejected.
# shellcheck disable=SC2086
out=$("$UCODE_BIN" -L "$UCODE_LIB_DIR" -e '
    let reg = require("builder.protocols.registry");
    try {
        reg.register({
            kind: "outbound", type: "badshared", sing_box_type: "x",
            shared: { wat: true },
            fields: [ { name: "f", type: "string", tab: "basic" } ],
            emit: function(s) { return {}; },
        });
        print("REGISTERED");
    } catch (e) { print("REJECTED"); }
' 2>&1)
case "$out" in
    "REJECTED") echo "PASS: unknown shared key rejected" ;;
    *) echo "FAIL: bad shared key not rejected [$out]"; exit 1 ;;
esac

# Test 4: _show_advanced_<tab> auto-injected and prepended first.
# shellcheck disable=SC2086
out=$("$UCODE_BIN" -L "$UCODE_LIB_DIR" -e '
    let reg = require("builder.protocols.registry");
    reg.register({
        kind: "dns", type: "advdemo", sing_box_type: "x",
        fields: [
            { name: "basic_f", type: "string", tab: "basic" },
            { name: "adv_f",   type: "string", tab: "basic", advanced: true },
        ],
        emit: function(s) { return {}; },
    });
    let m = reg.materialize("dns", "advdemo");
    print(m.fields[0].name);
')
case "$out" in
    "_show_advanced_basic") echo "PASS: advanced toggle prepended" ;;
    *) echo "FAIL: not prepended, first field=[$out]"; exit 1 ;;
esac

echo "ALL PASS: test_descriptor_materialize"
