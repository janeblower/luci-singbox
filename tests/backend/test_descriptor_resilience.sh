#!/bin/sh
# tests/test_descriptor_resilience.sh — S2.1: a broken built-in descriptor must
# log+skip, not abort ALL config generation. outbound.uc / inbound.uc wrap their
# eager require() so one malformed descriptor file degrades gracefully instead
# of throwing an assert through require() and killing generation for every
# protocol. Before the fix, requiring outbound.uc with a broken trojan.uc threw
# and no outbound could be built at all.
set -e
. "$(dirname "$0")/../lib/sb_helpers.sh"
UCODE_BIN="${UCODE_BIN:-ucode}"
APP_LIB="${UCODE_APP_LIB_DIR:-${SB_LIB}}"
command -v "$UCODE_BIN" >/dev/null 2>&1 || { echo "SKIP test_descriptor_resilience (ucode missing)"; exit 0; }

TMPDIR=$(mktemp -d); trap 'rm -rf "$TMPDIR"' EXIT
mkdir -p "$TMPDIR/overlay/builder/protocols"
# A broken outbound descriptor: register() asserts emit is a function; this file
# provides none, so require()-ing it throws at load. Placed first on the -L path
# so it shadows the real trojan descriptor.
cat > "$TMPDIR/overlay/builder/protocols/trojan.uc" <<'EOF'
require("builder.protocols.registry").register({ kind: "outbound", type: "trojan" });
return {};
EOF

run() { "$UCODE_BIN" -L "$TMPDIR/overlay" -L "$APP_LIB" -e "$1" 2>"$TMPDIR/err"; }

# Outbound: a broken trojan descriptor must not stop vless from generating.
out=$(run '
    let ob = require("outbound");
    let v = ob.build_constructor_for(
        { ".name":"v", "type":"vless", "server":"e.com", "server_port":"443",
          "server_uuid":"11111111-1111-1111-1111-111111111111" }, "vless");
    print(v ? v.type : "NULL");
') || true
[ "$out" = "vless" ] || { echo "FAIL(S2.1): vless must still generate when trojan descriptor is broken; got '$out'"; cat "$TMPDIR/err"; exit 1; }
grep -qi "trojan" "$TMPDIR/err" || { echo "FAIL(S2.1): a broken descriptor load must be logged"; cat "$TMPDIR/err"; exit 1; }
echo "  PASS: S2.1 outbound — broken descriptor logs+skips; other protocols still generate"

# Inbound: same guarantee via inbound.uc's wrapped requires.
out=$(run '
    let inb = require("inbound");
    let r = inb.build_one(
        { ".name":"vi", "protocol":"vless", "listen_port":"443",
          "server_uuid":"11111111-1111-1111-1111-111111111111" });
    print(r ? r.type : "NULL");
') || true
[ "$out" = "vless" ] || { echo "FAIL(S2.1): vless inbound must still generate when trojan descriptor is broken; got '$out'"; cat "$TMPDIR/err"; exit 1; }
echo "  PASS: S2.1 inbound — broken descriptor logs+skips; other protocols still generate"

echo "OK"
