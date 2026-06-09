#!/bin/sh
# tests/test_uci_defaults_fwmark.sh
set -e

SCRIPT=luci-app-singbox-ui/root/etc/uci-defaults/90-singbox-ui-fwmark
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing or not executable"; exit 1; }

# The script uses real `uci` — skip when not on a UCI host.
if ! command -v uci >/dev/null 2>&1; then
	echo "SKIP: uci not available"; exit 0
fi

UCI_DIR=$(mktemp -d)
export UCI_CONFIG_DIR="$UCI_DIR"
touch "$UCI_DIR/singbox-ui"

echo "-- first run seeds three defaults"
sh "$SCRIPT"
[ "$(uci get singbox-ui.@global[0].fwmark)" = "0x1" ] \
	|| { echo FAIL fwmark; exit 1; }
[ "$(uci get singbox-ui.@global[0].fwmark_mask)" = "0x1" ] \
	|| { echo FAIL fwmask; exit 1; }
[ "$(uci get singbox-ui.@global[0].redirect_router_traffic)" = "0" ] \
	|| { echo FAIL router_out; exit 1; }

echo "-- second run is idempotent (no value change)"
sh "$SCRIPT"
[ "$(uci get singbox-ui.@global[0].fwmark)" = "0x1" ] \
	|| { echo FAIL fwmark; exit 1; }

echo "-- does not overwrite user-set values"
uci set singbox-ui.@global[0].fwmark='0x100'
uci commit singbox-ui
sh "$SCRIPT"
[ "$(uci get singbox-ui.@global[0].fwmark)" = "0x100" ] \
	|| { echo "FAIL: overwritten user value"; exit 1; }

rm -rf "$UCI_DIR"
echo "OK"
