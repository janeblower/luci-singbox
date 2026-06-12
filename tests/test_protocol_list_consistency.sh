#!/bin/sh
# tests/test_protocol_list_consistency.sh
# S4-2: OUTBOUND_PROXY_KINDS must stay 1:1 with the registered outbound proxy
# descriptors. The registry (after require("outbound") eager-loads all
# descriptors) is the single source of truth; this guards against the list and
# the loaded descriptors drifting apart. `direct` is a registered outbound that
# is deliberately NOT a proxy kind (own dispatch branch), so it is excluded.
set -eu
cd "$(dirname "$0")/.."

UCODE_BIN="${UCODE_BIN:-ucode}"
UCODE_LIB_DIR="${UCODE_LIB_DIR:-luci-singbox-ui/root/usr/share/singbox-ui/lib}"
command -v "$UCODE_BIN" >/dev/null 2>&1 || { echo "SKIP test_protocol_list_consistency (ucode missing)"; exit 0; }

# NON_PROXY_OUTBOUNDS mirrors the deliberate exclusions in helpers.uc.
out=$("$UCODE_BIN" -L "$UCODE_LIB_DIR" -e '
    require("outbound");                       // eager-load all descriptors
    let reg = require("protocols.registry");
    let helpers = require("helpers");
    // registered outbounds with their own dispatch branch (not proxy kinds):
    // direct (iface/direct), and the Task 4 raw passthrough types json/sharelink.
    let non_proxy = { direct: 1, json: 1, sharelink: 1 };
    let registered = reg.types_for_kind("outbound");
    let problems = [];
    // 1) every registered outbound proxy must be in OUTBOUND_PROXY_KINDS
    for (let t in registered) {
        if (non_proxy[t]) continue;
        if (!helpers.is_outbound_proxy_kind(t))
            push(problems, "registered-but-not-listed:" + t);
    }
    // 2) every listed proxy kind must have a registered descriptor
    for (let t in helpers.OUTBOUND_PROXY_KINDS) {
        if (reg.get("outbound", t) == null)
            push(problems, "listed-but-not-registered:" + t);
    }
    print(length(problems) ? join(",", problems) : "CONSISTENT");
')
[ "$out" = "CONSISTENT" ] || { echo "FAIL: protocol list desync [$out]"; exit 1; }
echo "PASS: test_protocol_list_consistency"
