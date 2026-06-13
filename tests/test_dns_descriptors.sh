#!/bin/sh
set -eu
LIB="luci-singbox-ui/root/usr/share/singbox-ui/lib"
UCODE="${UCODE_BIN:-ucode}"
command -v "$UCODE" >/dev/null 2>&1 || { echo "SKIP: no ucode"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/t.uc" <<'UC'
require("builder.dns.registry");   // eager-loads all dns descriptors
let reg = require("builder.protocols.registry");
let want = ["udp","tcp","tls","quic","https","h3","fakeip","local","hosts","dhcp","mdns","tailscale","resolved","legacy"];
let got = reg.types_for_kind("dns");
let set = {}; for (let t in got) set[t] = 1;
for (let w in want) if (!set[w]) print("MISSING:" + w + "\n");
print("count=" + length(got) + "\n");
UC
out="$("$UCODE" -L "$LIB" "$WORK/t.uc")"
echo "$out" | grep -q "MISSING:" && { echo "FAIL: $out"; exit 1; }
echo "$out" | grep -q "count=14" || { echo "FAIL: expected 14 dns types: $out"; exit 1; }
echo "PASS"
