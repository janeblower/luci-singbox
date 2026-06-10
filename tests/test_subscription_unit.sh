#!/bin/sh
# tests/test_subscription_unit.sh
# Unit-tests the pure / injectable functions of subscription.uc by importing
# the script as a module (require), not via the full network path.
set -e
cd "$(dirname "$0")/.."

APP_LIB="${UCODE_APP_LIB_DIR:-$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/lib}"
SUB_DIR="$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui"

# Mirror test_subscription_uc.sh: skip if ucode/uci-mod unavailable on dev box.
# In addition, add the script's own directory to the lib flags so that
# require("subscription") resolves subscription.uc off the -L search path.
if command -v ucode >/dev/null 2>&1; then
	UCODE_BIN=ucode
	UCODE_LIB_FLAGS="-L $APP_LIB -L $SUB_DIR"
elif [ -x "${UCODE_BIN:-}" ] && [ -d "${UCODE_STUB_DIR:-}" ]; then
	UCODE_LIB_FLAGS="-L $UCODE_STUB_DIR"
	[ -n "${UCODE_LIB_DIR:-}" ] && UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L $UCODE_LIB_DIR"
	UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L $APP_LIB -L $SUB_DIR"
else
	echo "SKIP: ucode not available"
	exit 0
fi

pass() { echo "  PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

run_uc() {
	# shellcheck disable=SC2086
	"$UCODE_BIN" $UCODE_LIB_FLAGS -e "$1"
}

echo "-- S3-6: try_b64_decode is exported and decodes scheme-bearing base64"
out=$(run_uc '
	let sub = require("subscription");
	// b64("vless://uuid@host:443\n") — decoded line starts with a known scheme.
	print(sub.try_b64_decode("dmxlc3M6Ly91dWlkQGhvc3Q6NDQzCg==") + "\n");
')
echo "$out" | grep -q '^vless://uuid@host:443' \
	|| { echo "[$out]"; fail "S3-6: try_b64_decode did not decode scheme-bearing b64"; }
pass "S3-6: scheme-bearing base64 is decoded"

echo "-- S3-6: try_b64_decode passes through non-scheme payloads unchanged"
out=$(run_uc '
	let sub = require("subscription");
	// b64("visit https://example.com/path") decodes to plaintext with no
	// LINE starting with a scheme -> must be returned as the original b64.
	let s = "dmlzaXQgaHR0cHM6Ly9leGFtcGxlLmNvbS9wYXRo";
	print((sub.try_b64_decode(s) === s) ? "same" : "changed");
')
[ "$out" = "same" ] || { echo "[$out]"; fail "S3-6: non-scheme b64 should pass through unchanged"; }
pass "S3-6: non-scheme payload passes through"

echo "ALL PASS"
