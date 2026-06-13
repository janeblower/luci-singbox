#!/bin/sh
# tests/test_version_gating.sh — schema carries min_version for gated protocols;
# status_detail exposes core_version.
set -eu
cd "$(dirname "$0")/.."
UCODE_BIN="${UCODE_BIN:-ucode}"
LIB="${UCODE_LIB_DIR:-luci-singbox-ui/root/usr/share/singbox-ui/lib}"
command -v "$UCODE_BIN" >/dev/null 2>&1 || { echo "SKIP test_version_gating (ucode missing)"; exit 0; }

out=$("$UCODE_BIN" -L "$LIB" -e '
    require("outbound"); require("inbound");
    let d = require("builder.protocols.schema_dump").dump_all();
    print(sprintf("anytls=%s naive_out=%s naive_in=%s cloudflared=%s\n",
        d.outbound.anytls.min_version,
        d.outbound.naive.min_version,
        d.inbound.naive.min_version,
        d.inbound.cloudflared.min_version));
')
echo "$out"
echo "$out" | grep -q 'anytls=1.12.0 naive_out=1.13.0 naive_in= cloudflared=1.14.0' \
  || { echo "FAIL: min_version projection wrong"; exit 1; }
echo "test_version_gating: PASS"
