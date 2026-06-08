#!/bin/sh
# tests/test_shared_tls.sh — emit_outbound / emit_inbound shapes for the
# shared TLS block. Covers: disabled (null), minimal enabled, Reality client,
# ECH, TLS fragment, uTLS, hysteria2 force-enabled.
set -eu
cd "$(dirname "$0")/.."

UCODE_BIN="${UCODE_BIN:-ucode}"
UCODE_LIB_DIR="${UCODE_LIB_DIR:-luci-app-singbox-ui/root/usr/share/singbox-ui/lib}"

if ! command -v "$UCODE_BIN" >/dev/null 2>&1; then
    echo "SKIP test_shared_tls (ucode missing)"; exit 0
fi

je() { "$UCODE_BIN" -L "$UCODE_LIB_DIR" -e "$1"; }

# Test 1: tls_enabled=0 → emit_outbound returns null.
out=$(je '
    let tls = require("protocols._shared.tls");
    let r = tls.emit_outbound({ tls_enabled: "0" });
    print(r == null ? "NULL" : "NOTNULL");
')
[ "$out" = "NULL" ] || { echo "FAIL: emit_outbound disabled [$out]"; exit 1; }
echo "PASS: emit_outbound disabled → null"

# Test 2: tls_enabled=1 + tls_server_name → enabled+server_name.
out=$(je '
    let tls = require("protocols._shared.tls");
    let r = tls.emit_outbound({ tls_enabled: "1", tls_server_name: "ex.com" });
    print(sprintf("%s|%s", r.enabled, r.server_name));
')
[ "$out" = "true|ex.com" ] || { echo "FAIL: minimal enabled [$out]"; exit 1; }
echo "PASS: emit_outbound minimal enabled"

# Test 2b: alpn arrives as a JSON array (guard against as_array() regressions).
out=$(je '
    let tls = require("protocols._shared.tls");
    let r = tls.emit_outbound({ tls_enabled: "1", tls_alpn: ["h2", "http/1.1"] });
    print(sprintf("%s|%d|%s", type(r.alpn), length(r.alpn), r.alpn[0]));
')
[ "$out" = "array|2|h2" ] || { echo "FAIL: alpn array [$out]"; exit 1; }
echo "PASS: emit_outbound alpn is array"

# Test 3: Reality client.
out=$(je '
    let tls = require("protocols._shared.tls");
    let r = tls.emit_outbound({
        tls_enabled: "1", reality_enabled: "1",
        reality_public_key: "pk", reality_short_id: "00ff"
    });
    print(sprintf("%s|%s|%s", r.reality.enabled, r.reality.public_key, r.reality.short_id));
')
[ "$out" = "true|pk|00ff" ] || { echo "FAIL: Reality client [$out]"; exit 1; }
echo "PASS: emit_outbound Reality client"

# Regression guard: tls.reality.short_id must be a string, not an array (Phase B fix).
out=$(je '
    let tls = require("protocols._shared.tls");
    let r = tls.emit_outbound({
        tls_enabled: "1", reality_enabled: "1",
        reality_public_key: "pk", reality_short_id: "00ff"
    });
    print(type(r.reality.short_id));
')
[ "$out" = "string" ] || { echo "FAIL: short_id type [$out]"; exit 1; }
echo "PASS: emit_outbound Reality short_id is string not array"

# Test 3b: inbound Reality — private_key + handshake server.
out=$(je '
    let tls = require("protocols._shared.tls");
    let r = tls.emit_inbound({
        tls_enabled: "1", reality_enabled: "1",
        reality_private_key: "pkv", reality_short_id: "00ff",
        reality_handshake_server: "h.example", reality_handshake_server_port: "443",
    });
    print(sprintf("%s|%s|%s|%d", r.reality.enabled, r.reality.private_key, r.reality.handshake.server, r.reality.handshake.server_port));
')
[ "$out" = "true|pkv|h.example|443" ] || { echo "FAIL: Reality inbound [$out]"; exit 1; }
echo "PASS: emit_inbound Reality server"

# Test 4: uTLS client.
out=$(je '
    let tls = require("protocols._shared.tls");
    let r = tls.emit_outbound({
        tls_enabled: "1", utls_enabled: "1", utls_fingerprint: "firefox"
    });
    print(sprintf("%s|%s", r.utls.enabled, r.utls.fingerprint));
')
[ "$out" = "true|firefox" ] || { echo "FAIL: uTLS [$out]"; exit 1; }
echo "PASS: emit_outbound uTLS"

# Test 5: hysteria2 force-enabled (tls_enabled=0 ignored).
out=$(je '
    let tls = require("protocols._shared.tls");
    let r = tls.emit_outbound({ tls_enabled: "0" }, { force_enabled: true });
    print(r == null ? "NULL" : sprintf("%s", r.enabled));
')
[ "$out" = "true" ] || { echo "FAIL: force_enabled [$out]"; exit 1; }
echo "PASS: emit_outbound force_enabled (hysteria2)"

# Test 6: TLS fragment (advanced).
out=$(je '
    let tls = require("protocols._shared.tls");
    let r = tls.emit_outbound({
        tls_enabled: "1", tls_fragment: "1",
        tls_fragment_fallback_delay: "500ms",
    });
    print(sprintf("%s|%s", r.fragment, r.fragment_fallback_delay));
')
[ "$out" = "true|500ms" ] || { echo "FAIL: fragment [$out]"; exit 1; }
echo "PASS: emit_outbound fragment"

# Test 7: server-side ECH (key path, not config path).
out=$(je '
    let tls = require("protocols._shared.tls");
    let r = tls.emit_inbound({
        tls_enabled: "1", tls_ech_enabled: "1",
        tls_ech_key_path: "/etc/sb/ech.key",
    });
    print(sprintf("%s|%s", r.ech.enabled, r.ech.key_path));
')
[ "$out" = "true|/etc/sb/ech.key" ] || { echo "FAIL: server ECH [$out]"; exit 1; }
echo "PASS: emit_inbound ECH key_path"

# Test 8: fields[] includes the gate + reality sub-toggle + ECH advanced.
out=$(je '
    let tls = require("protocols._shared.tls");
    let names = "";
    for (let f in tls.fields) names += f.name + ",";
    print(names);
')
case "$out" in
    *"tls_enabled,"*) ;;
    *) echo "FAIL: fields missing tls_enabled [$out]"; exit 1 ;;
esac
case "$out" in
    *"reality_enabled,"*) ;;
    *) echo "FAIL: fields missing reality_enabled [$out]"; exit 1 ;;
esac
echo "PASS: fields[] includes gate + reality_enabled"

echo "ALL PASS: test_shared_tls"
