#!/bin/sh
# tests/test_ssh_descriptor_groups.sh
# Asserts every field in the SSH outbound descriptor declares an explicit
# `group`. Without this, fields fall through to the default 'advanced' tab
# in lib/descriptor_form.js and pollute the modal layout for unrelated
# protocols (the VLESS-only-Credentials regression — phase E1).
set -e
cd "$(dirname "$0")/.."

UCODE_BIN="${UCODE_BIN:-$(command -v ucode || true)}"
if [ -z "$UCODE_BIN" ] || [ ! -x "$UCODE_BIN" ]; then
    echo "SKIP test_ssh_descriptor_groups (ucode missing)"
    exit 0
fi

UCODE_LIB_FLAGS="-L luci-app-singbox-ui/root/usr/share/singbox-ui/lib"
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS -e '
    require("protocols.ssh");
    let reg = require("protocols.registry");
    let d = reg.get("outbound", "ssh");
    let missing = [];
    for (let f in d.fields)
        if (f.group == null || f.group == "")
            push(missing, f.name);
    print(length(missing) ? join(",", missing) : "ok", chr(10));
')

if [ "$out" != "ok" ]; then
    echo "FAIL: SSH fields without explicit group: $out"
    exit 1
fi
echo "PASS test_ssh_descriptor_groups"
