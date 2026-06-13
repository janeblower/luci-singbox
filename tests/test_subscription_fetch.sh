#!/bin/sh
# Unit-tests subscription.uc fetch wiring with injected seams (no sing-box, no net).
set -eu
LIB="luci-singbox-ui/root/usr/share/singbox-ui"
UCODE="${UCODE_BIN:-ucode}"
command -v "$UCODE" >/dev/null 2>&1 || { echo "SKIP: no ucode"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export UCI_CONFIG_DIR="$WORK/config"; mkdir -p "$UCI_CONFIG_DIR"
cat > "$UCI_CONFIG_DIR/singbox-ui" <<'UCI'
config outbound 'proxy1'
	option type 'trojan'
	option server 'example.com'
	option server_port '443'
	option server_password 'pw'

config outbound 'mysub'
	option type 'subscription'
	option sub_url 'https://sub.example.com/x'
	option sub_update_via 'proxy1'
	option sub_interval '3600'
UCI

# Test A: build_fetch_config(via=proxy1) yields outbounds [proxy1(trojan), direct].
cat > "$WORK/probe.uc" <<UC
let sub = require("subscription");
let uci = require("uci").cursor("$UCI_CONFIG_DIR");
print(sub._build_fetch_config_for_test(uci, "proxy1"));
UC
out="$("$UCODE" -L "$LIB/lib" -L "$LIB" "$WORK/probe.uc")"
echo "$out" | grep -q '"type"' && echo "$out" | grep -q 'trojan' || { echo "FAIL: via outbound not in fetch config"; echo "$out"; exit 1; }
echo "$out" | grep -q '"tag"' && echo "$out" | grep -q 'direct' || { echo "FAIL: direct outbound missing"; exit 1; }
echo "$out" | grep -q 'proxy1' || { echo "FAIL: via tag not set"; exit 1; }

# Test B: via=direct yields only the direct outbound (no proxy leaked).
cat > "$WORK/probe2.uc" <<UC
let sub = require("subscription");
let uci = require("uci").cursor("$UCI_CONFIG_DIR");
print(sub._build_fetch_config_for_test(uci, "direct"));
UC
out2="$("$UCODE" -L "$LIB/lib" -L "$LIB" "$WORK/probe2.uc")"
echo "$out2" | grep -q 'direct' || { echo "FAIL: direct missing"; exit 1; }
echo "$out2" | grep -q 'trojan' && { echo "FAIL: via=direct leaked a proxy"; exit 1; } || true

echo "PASS"
