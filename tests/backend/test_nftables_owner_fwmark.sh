#!/bin/sh
# tests/test_nftables_owner_fwmark.sh
# Host/VM test for gather_apply_params via the read-only `params` CLI:
#  - per-inbound fwmark wins over global, mask is derived = mark
#  - fakeip nft_rules=0 contributes no ranges
#  - no tproxy owner → transparent=0 (apply becomes a no-op)
set -e
. "$(dirname "$0")/../lib/sb_helpers.sh"

SCRIPT=${SB_SHARE}/nftables.uc
LIB=${UCODE_APP_LIB_DIR:-$PWD/${SB_LIB}}

if ! command -v ucode >/dev/null 2>&1; then echo "SKIP: ucode not available"; exit 0; fi

# params needs a real uci cursor over a config dir. Probe the uci capability
# DIRECTLY (module import + cursor over a dir) rather than running the full
# `params` path — that way a bug inside gather_apply_params surfaces as a real
# FAIL in the cases below instead of being masked as a SKIP. Skip only when the
# uci module itself is unavailable (host without libuci).
probe=$(mktemp -d)
if ! ucode -L "$LIB" -e 'let u = require("uci"); exit(u && u.cursor("'"$probe"'") ? 0 : 1);' >/dev/null 2>&1; then
	rm -rf "$probe"; echo "SKIP: ucode uci module unavailable on host"; exit 0
fi
rm -rf "$probe"

params() {
	UCI_CONFIG_DIR="$1" ucode -L "$LIB" "$SCRIPT" params
}

D=$(mktemp -d); trap 'rm -rf "$D"' EXIT

echo "-- per-inbound fwmark wins, mask derived"
cat >"$D/singbox-ui" <<'EOF'
config inbound 'tp'
	option enabled '1'
	option protocol 'tproxy'
	option listen_port '7895'
	option nft_rules '1'
	option fwmark '0x123'
config dns_server 'fk'
	option enabled '1'
	option type 'fakeip'
	option inet4_range '198.18.0.0/15'
EOF
out=$(params "$D")
echo "$out" | grep -q '"mark":"0x123"' || { echo "FAIL mark: $out"; exit 1; }
echo "$out" | grep -q '"mask":"0x123"' || { echo "FAIL mask: $out"; exit 1; }
echo "$out" | grep -q '"transparent":1' || { echo "FAIL transparent: $out"; exit 1; }
echo "$out" | grep -q '"v4":"198.18.0.0/15"' || { echo "FAIL v4: $out"; exit 1; }

echo "-- no per-inbound fwmark → global fallback"
cat >"$D/singbox-ui" <<'EOF'
config global 'g'
	option fwmark '0x5'
	option fwmark_mask '0x5'
config inbound 'tp'
	option enabled '1'
	option protocol 'tproxy'
	option listen_port '7895'
	option nft_rules '1'
EOF
out=$(params "$D")
echo "$out" | grep -q '"mark":"0x5"' || { echo "FAIL global mark: $out"; exit 1; }

echo "-- fakeip nft_rules=0 contributes no ranges"
cat >"$D/singbox-ui" <<'EOF'
config inbound 'tp'
	option enabled '1'
	option protocol 'tproxy'
	option listen_port '7895'
	option nft_rules '1'
config dns_server 'fk'
	option enabled '1'
	option type 'fakeip'
	option inet4_range '198.18.0.0/15'
	option nft_rules '0'
EOF
out=$(params "$D")
echo "$out" | grep -q '"v4":""' || { echo "FAIL fakeip gate v4: $out"; exit 1; }

echo "-- no tproxy nft owner → transparent=0"
cat >"$D/singbox-ui" <<'EOF'
config inbound 'tp'
	option enabled '1'
	option protocol 'tproxy'
	option listen_port '7895'
	option nft_rules '0'
EOF
out=$(params "$D")
echo "$out" | grep -q '"transparent":0' || { echo "FAIL transparent off: $out"; exit 1; }

echo "-- ruleset nft no-op when no tproxy owner (transparent=0 regardless of rs files)"
mkdir -p /tmp/singbox-ui
cat >/tmp/singbox-ui/rs_gatetest.json <<'JSON'
{"rules":[{"ip_cidr":["8.8.8.0/24"],"network":"","port_range":[]}]}
JSON
cat >"$D/singbox-ui" <<'EOF'
config inbound 'tp'
	option enabled '1'
	option protocol 'tproxy'
	option listen_port '7895'
	option nft_rules '0'
config ruleset 'gatetest'
	option enabled '1'
	option type 'remote'
	option nft_rules '1'
EOF
out=$(params "$D")
rm -f /tmp/singbox-ui/rs_gatetest.json
echo "$out" | grep -q '"transparent":0' \
	|| { echo "FAIL: ruleset present but no tproxy owner should still be transparent=0: $out"; exit 1; }

echo "OK: nftables owner/fwmark params tests passed"
