#!/bin/sh
# tests/test_shared_tls.sh — declarative emit_spec path via filler for the
# shared TLS block. Covers: disabled (null), minimal enabled, Reality client,
# ECH, TLS fragment, uTLS, hysteria2 force-enabled.
set -eu
cd "$(dirname "$0")/.."

UCODE_BIN="${UCODE_BIN:-ucode}"
UCODE_LIB_DIR="${UCODE_LIB_DIR:-luci-singbox-ui/root/usr/share/singbox-ui/lib}"

if ! command -v "$UCODE_BIN" >/dev/null 2>&1; then
    echo "SKIP test_shared_tls (ucode missing)"; exit 0
fi

je() { "$UCODE_BIN" -L "$UCODE_LIB_DIR" -e "$1"; }

# Helper: build outbound tls block via filler
# f.build({kind:"outbound",sing_box_type:"x",fields:[],shared:{tls:<opts>}}, s)
# → got.tls (or null)

# Test 1: tls_enabled=0 → no tls key in result (block gated out).
out=$(je '
    let f = require("builder._filler");
    let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ tls:{} } },
        { ".name":"t", tls_enabled:"0" }
    );
    print(got.tls == null ? "NULL" : "NOTNULL");
')
[ "$out" = "NULL" ] || { echo "FAIL: tls disabled [$out]"; exit 1; }
echo "PASS: tls disabled → null"

# Test 2: tls_enabled=1 + tls_server_name → enabled+server_name.
out=$(je '
    let f = require("builder._filler");
    let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ tls:{} } },
        { ".name":"t", tls_enabled:"1", tls_server_name:"ex.com" }
    );
    print(sprintf("%s|%s", got.tls.enabled, got.tls.server_name));
')
[ "$out" = "true|ex.com" ] || { echo "FAIL: minimal enabled [$out]"; exit 1; }
echo "PASS: tls minimal enabled"

# Test 2b: alpn arrives as a JSON array (guard against as_array() regressions).
out=$(je '
    let f = require("builder._filler");
    let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ tls:{} } },
        { ".name":"t", tls_enabled:"1", tls_alpn:["h2","http/1.1"] }
    );
    print(sprintf("%s|%d|%s", type(got.tls.alpn), length(got.tls.alpn), got.tls.alpn[0]));
')
[ "$out" = "array|2|h2" ] || { echo "FAIL: alpn array [$out]"; exit 1; }
echo "PASS: tls alpn is array"

# Test 3: Reality client.
out=$(je '
    let f = require("builder._filler");
    let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ tls:{} } },
        { ".name":"t", tls_enabled:"1", reality_enabled:"1",
          reality_public_key:"pk", reality_short_id:"00ff" }
    );
    print(sprintf("%s|%s|%s", got.tls.reality.enabled, got.tls.reality.public_key, got.tls.reality.short_id));
')
[ "$out" = "true|pk|00ff" ] || { echo "FAIL: Reality client [$out]"; exit 1; }
echo "PASS: tls Reality client"

# Regression guard: tls.reality.short_id must be a string, not an array (Phase B fix).
out=$(je '
    let f = require("builder._filler");
    let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ tls:{} } },
        { ".name":"t", tls_enabled:"1", reality_enabled:"1",
          reality_public_key:"pk", reality_short_id:"00ff" }
    );
    print(type(got.tls.reality.short_id));
')
[ "$out" = "string" ] || { echo "FAIL: short_id type [$out]"; exit 1; }
echo "PASS: tls Reality short_id is string not array"

# Test 3b: inbound Reality — private_key + handshake server.
out=$(je '
    let f = require("builder._filler");
    let got = f.build(
        { kind:"inbound", sing_box_type:"trojan", fields:[], shared:{ tls:{} } },
        { ".name":"t", listen_port:"443", tls_enabled:"1", reality_enabled:"1",
          reality_private_key:"pkv", reality_short_id:"00ff",
          reality_handshake_server:"h.example", reality_handshake_server_port:"443" }
    );
    print(sprintf("%s|%s|%s|%d",
        got.tls.reality.enabled, got.tls.reality.private_key,
        got.tls.reality.handshake.server, got.tls.reality.handshake.server_port));
')
[ "$out" = "true|pkv|h.example|443" ] || { echo "FAIL: Reality inbound [$out]"; exit 1; }
echo "PASS: tls Reality inbound server"

# Test 4: uTLS client.
out=$(je '
    let f = require("builder._filler");
    let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ tls:{} } },
        { ".name":"t", tls_enabled:"1", utls_enabled:"1", utls_fingerprint:"firefox" }
    );
    print(sprintf("%s|%s", got.tls.utls.enabled, got.tls.utls.fingerprint));
')
[ "$out" = "true|firefox" ] || { echo "FAIL: uTLS [$out]"; exit 1; }
echo "PASS: tls uTLS"

# Test 5: hysteria2 force-enabled (tls_enabled=0 ignored).
out=$(je '
    let f = require("builder._filler");
    let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ tls:{ force_enabled:true } } },
        { ".name":"t", tls_enabled:"0" }
    );
    print(got.tls == null ? "NULL" : sprintf("%s", got.tls.enabled));
')
[ "$out" = "true" ] || { echo "FAIL: force_enabled [$out]"; exit 1; }
echo "PASS: tls force_enabled (hysteria2)"

# Test 6: TLS fragment (advanced).
out=$(je '
    let f = require("builder._filler");
    let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ tls:{} } },
        { ".name":"t", tls_enabled:"1", tls_fragment:"1",
          tls_fragment_fallback_delay:"500ms" }
    );
    print(sprintf("%s|%s", got.tls.fragment, got.tls.fragment_fallback_delay));
')
[ "$out" = "true|500ms" ] || { echo "FAIL: fragment [$out]"; exit 1; }
echo "PASS: tls fragment"

# Test 7: server-side ECH (key path, not config path).
out=$(je '
    let f = require("builder._filler");
    let got = f.build(
        { kind:"inbound", sing_box_type:"trojan", fields:[], shared:{ tls:{} } },
        { ".name":"t", listen_port:"443", tls_enabled:"1", tls_ech_enabled:"1",
          tls_ech_key_path:"/etc/sb/ech.key" }
    );
    print(sprintf("%s|%s", got.tls.ech.enabled, got.tls.ech.key_path));
')
[ "$out" = "true|/etc/sb/ech.key" ] || { echo "FAIL: server ECH [$out]"; exit 1; }
echo "PASS: tls inbound ECH key_path"

# Test 8: fields[] includes the gate + reality sub-toggle + ECH advanced.
out=$(je '
    let tls = require("builder._shared.tls");
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

# Test 9: tls_alpn stays a free-entry list but now carries combobox
# suggestions (h2 / http/1.1 / h3); tls_cipher_suites carries suggestions too.
out=$(je '
    let tls = require("builder._shared.tls");
    let alpn = null, cs = null;
    for (let f in tls.fields) {
        if (f.name == "tls_alpn")          alpn = f;
        if (f.name == "tls_cipher_suites") cs   = f;
    }
    print(sprintf("%s|%d|%s|%s|%s|%d",
        alpn.type, length(alpn.values), alpn.values[0], alpn.values[2],
        cs.type, length(cs.values)));
')
case "$out" in
    "list|3|h2|h3|list|"[1-9]*) echo "PASS: tls_alpn/cipher_suites combobox suggestions" ;;
    *) echo "FAIL: tls suggestion values [$out]"; exit 1 ;;
esac

echo "ALL PASS: test_shared_tls"
