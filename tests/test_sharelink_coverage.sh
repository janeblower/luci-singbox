#!/bin/sh
# tests/test_sharelink_coverage.sh — guards that the declarative share-link
# map can never silently drop a parameter: (1) every INVENTORY param has a SPEC
# disposition and vice-versa (completeness), (2) a maximal link per scheme lands
# at its declared sing-box path (behavioral). Also unit-tests the apply_params
# engine (set_path / coerce / gates).
set -eu
cd "$(dirname "$0")/.."
UCODE_BIN="${UCODE_BIN:-ucode}"
UCODE_LIB_DIR="${UCODE_LIB_DIR:-luci-singbox-ui/root/usr/share/singbox-ui/lib}"
command -v "$UCODE_BIN" >/dev/null 2>&1 || { echo "SKIP test_sharelink_coverage (ucode missing)"; exit 0; }

je() { "$UCODE_BIN" -L "$UCODE_LIB_DIR" -e "$1"; }
ok() { echo "  PASS: $1"; }
die() { echo "FAIL: $1 (got: $2)"; exit 1; }

# --- engine: set_path creates nested objects, coerce transforms, gates apply ---
out=$(je '
    let m = require("sharelink_map");
    let o = {};
    m.apply_params(
        { sni: "x.com", alpn: "h2,http/1.1", ins: "1", off: "0", n: "100 mbps" },
        [
            { param: "sni",  path: "tls.server_name", enables: "tls.utls.enabled" },
            { param: "alpn", path: "tls.alpn", transform: "csv" },
            { param: "ins",  path: "tls.insecure", transform: "bool" },
            { param: "off",  path: "tls.never",    transform: "bool" },
            { param: "n",    path: "up_mbps",      transform: "int" },
            { param: "gated", path: "should.not", when: { sni: "other" } },
            { param: "hand", handler: "x" },
            { param: "uns",  unsupported: "because" },
        ], o);
    print(sprintf("%s|%d|%s|%s|%s|%s|%s|%s",
        o.tls.server_name,
        length(o.tls.alpn),
        o.tls.insecure === true ? "T" : "?",
        o.tls.never == null ? "OMIT" : "LEAK",
        o.up_mbps,
        o.should == null ? "GATED" : "LEAK",
        o.hand == null ? "OK" : "LEAK",
        o.tls.utls.enabled === true ? "E" : "?"));
')
[ "$out" = "x.com|2|T|OMIT|100|GATED|OK|E" ] || die "engine apply_params" "$out"
ok "apply_params: set_path/csv/bool/int/gate/skip-handler"

# --- completeness: INVENTORY param set ≡ SPEC param set, per scheme ---
out=$(je '
    let m = require("sharelink_map");
    let problems = [];
    for (let scheme in m.INVENTORY) {
        let inv = {};
        for (let p in m.INVENTORY[scheme]) inv[p] = true;
        let spc = {};
        for (let e in (m.SPEC[scheme] ?? [])) spc[e.param] = true;
        for (let p in inv) if (!spc[p]) push(problems, sprintf("%s: INVENTORY param %s has no SPEC disposition", scheme, p));
        for (let p in spc) if (!inv[p]) push(problems, sprintf("%s: SPEC param %s not in INVENTORY", scheme, p));
    }
    print(length(problems) ? join("\n", problems) : "CLEAN");
')
[ "$out" = "CLEAN" ] || die "completeness INVENTORY<=>SPEC" "$out"
ok "completeness: every param has a disposition (and vice-versa)"

echo "OK"
