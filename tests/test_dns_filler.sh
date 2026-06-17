#!/bin/sh
set -eu
. "$(dirname "$0")/lib/sb_helpers.sh"
LIB="${SB_LIB}"
UCODE="${UCODE_BIN:-ucode}"
command -v "$UCODE" >/dev/null 2>&1 || { echo "SKIP: no ucode"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/t.uc" <<'UC'
let reg = require("builder.protocols.registry");
let filler = require("builder._filler");
reg.register({
  kind: "dns", type: "tls", sing_box_type: "tls",
  shared: { dial: {}, tls: {} },
  fields: [
    { name: "server", type: "string", tab: "basic", json_key: "server", omit_when: "never" },
    { name: "server_port", type: "number", tab: "basic", json_key: "server_port", coerce: "num" },
  ],
});
let d = reg.get("dns", "tls");
// section: a DoT server with a detour (dial) + TLS server_name.
// tls_enabled gates the tls block (enabled_field in emit_spec.gate).
// tls_server_name is the SNI field name from tls.uc fields[].
let s = { [".name"]: "dot1", server: "1.1.1.1", server_port: "853",
          detour: "proxy", tls_enabled: "1", tls_server_name: "cloudflare-dns.com" };
let out = filler.build(d, s);
print(sprintf("%J", out));
UC
out="$("$UCODE" -L "$LIB" "$WORK/t.uc")"
echo "$out" | grep -q '"type"' && echo "$out" | grep -q 'tls' || { echo "FAIL: type"; echo "$out"; exit 1; }
echo "$out" | grep -q '"tag"' && echo "$out" | grep -q 'dot1' || { echo "FAIL: tag"; exit 1; }
echo "$out" | grep -q '"server"' && echo "$out" | grep -q '1.1.1.1' || { echo "FAIL: server"; exit 1; }
echo "$out" | grep -q '"detour"' && echo "$out" | grep -q 'proxy' || { echo "FAIL: dial detour not merged"; exit 1; }
echo "$out" | grep -q '"tls"' || { echo "FAIL: tls block not built (dns->outbound direction)"; exit 1; }
echo "PASS"
