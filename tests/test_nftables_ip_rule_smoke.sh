#!/bin/sh
# tests/test_nftables_ip_rule_smoke.sh
# PATH-stub the `ip` command to feed canned `ip rule show` output to
# nftables.uc, then assert the smoke check logs a warning when no
# matching fwmark is present and stays quiet when one is.
set -e

if ! command -v ucode >/dev/null 2>&1; then
	echo "SKIP: ucode not available"; exit 0
fi

SCRIPT=$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/nftables.uc
LIB="-L $PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/lib"

# Mock UCI config dir with all the sections cmd_apply needs.
UCI=$(mktemp -d)
cat >"$UCI/singbox-ui" <<EOF
config global
	option fwmark '0x1'
	option fwmark_mask '0x1'
config dns_server fakeip
	option type 'fakeip'
	option enabled '1'
	option inet4_range '198.18.0.0/15'
	option inet6_range 'fc00::/18'
config inbound tp
	option protocol 'tproxy'
	option enabled '1'
	option nft_rules '1'
	option listen_port '7895'
	list interface 'br-lan'
EOF

# Two test runs: rule present (silent), rule absent (warn).
STUB=$(mktemp -d)

cat >"$STUB/ip" <<'EOF'
#!/bin/sh
# $1=-4 or -6, $2=rule, $3=show
if [ "$2" = "rule" ] && [ "$3" = "show" ]; then
	[ "$MOCK_HAS_RULE" = "1" ] && echo "100: from all fwmark 0x1/0x1 lookup 100" || true
fi
EOF
chmod +x "$STUB/ip"

# Stub `nft` so cmd_apply's `nft -f` returns success without doing anything.
cat >"$STUB/nft" <<'EOF'
#!/bin/sh
case "$1" in
	-f) cat >/dev/null; exit 0 ;;
	delete) exit 0 ;;
	*) exit 0 ;;
esac
EOF
chmod +x "$STUB/nft"

echo "-- smoke check: warns when no matching ip rule"
out=$(PATH="$STUB:$PATH" UCI_CONFIG_DIR="$UCI" MOCK_HAS_RULE=0 \
	ucode $LIB "$SCRIPT" apply 2>&1)
echo "$out" | grep -q 'no ip rule with fwmark 0x1/0x1' \
	|| { echo "FAIL: warning missing"; echo "$out"; exit 1; }

echo "-- smoke check: quiet when matching ip rule present"
out=$(PATH="$STUB:$PATH" UCI_CONFIG_DIR="$UCI" MOCK_HAS_RULE=1 \
	ucode $LIB "$SCRIPT" apply 2>&1)
echo "$out" | grep -q 'no ip rule with fwmark' \
	&& { echo "FAIL: warning fired even though rule was present"; echo "$out"; exit 1; }
:

rm -rf "$STUB" "$UCI"
echo "OK"
