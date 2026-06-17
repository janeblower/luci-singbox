#!/bin/sh
# tests/test_sharelink_coverage.sh — guards that the declarative share-link
# map can never silently drop a parameter: (1) every INVENTORY param has a SPEC
# disposition and vice-versa (completeness), (2) a maximal link per scheme lands
# at its declared sing-box path (behavioral). Also unit-tests the apply_params
# engine (set_path / coerce / gates).
set -eu
. "$(dirname "$0")/lib/sb_helpers.sh"
cd "$(dirname "$0")/.."
UCODE_BIN="${UCODE_BIN:-ucode}"
UCODE_LIB_DIR="${UCODE_LIB_DIR:-${SB_LIB}}"
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

# --- behavioral: a maximal link per scheme lands at declared sing-box paths ---
chk() { # name  url  ucode-expr-printing-result  expected
    out=$(je "let r = require('sharelink').parse_proxy_url('$2'); print($3);")
    [ "$out" = "$4" ] || die "behavioral $1" "$out"
    ok "behavioral $1"
}
chk vless \
  'vless://11111111-1111-1111-1111-111111111111@h.ex:443?security=reality&sni=s.com&pbk=PK&sid=ab&flow=xtls-rprx-vision&fp=chrome#n' \
  "sprintf('%s|%s|%s|%s', r.flow, r.tls.reality.short_id, r.tls.reality.public_key, r.tls.utls.fingerprint)" \
  'xtls-rprx-vision|ab|PK|chrome'
chk trojan \
  'trojan://pw@h.ex:443?sni=s.com&alpn=h2&type=grpc&serviceName=gs#n' \
  "sprintf('%s|%s|%s', r.tls.server_name, r.transport.type, r.transport.service_name)" \
  's.com|grpc|gs'
chk hysteria2 \
  'hy2://pw@h.ex:443?sni=s.com&insecure=1&alpn=h3#n' \
  "sprintf('%s|%s|%d', r.tls.server_name, r.tls.insecure===true?'T':'?', length(r.tls.alpn))" \
  's.com|T|1'
chk tuic \
  'tuic://11111111-1111-1111-1111-111111111111:pw@h.ex:443?congestion_control=bbr&sni=s.com#n' \
  "sprintf('%s|%s|%s', r.uuid, r.congestion_control, r.tls.server_name)" \
  '11111111-1111-1111-1111-111111111111|bbr|s.com'
chk hysteria1 \
  'hysteria://h.ex:443?auth=tok&peer=s.com&upmbps=50#n' \
  "sprintf('%s|%s|%d', r.auth_str, r.tls.server_name, r.up_mbps)" \
  'tok|s.com|50'
chk anytls \
  'anytls://pw@h.ex:443?sni=s.com&alpn=h2#n' \
  "sprintf('%s|%d', r.tls.server_name, length(r.tls.alpn))" \
  's.com|1'

echo "OK"
