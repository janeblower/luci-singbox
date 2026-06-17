#!/bin/sh
# tests/test_subscription_unit.sh
# Unit-tests the pure / injectable functions of subscription.uc by importing
# the script as a module (require), not via the full network path.
set -e
. "$(dirname "$0")/../lib/sb_helpers.sh"
cd "$(dirname "$0")/../.."

APP_LIB="${UCODE_APP_LIB_DIR:-$PWD/${SB_LIB}}"
SUB_DIR="$PWD/${SB_SHARE}"

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

echo "-- S3-7: _set_io_for_test installs an injectable reader"
out=$(run_uc '
	let sub = require("subscription");
	if (type(sub._set_io_for_test) !== "function") { print("no-setter\n"); exit(0); }
	let seen = [];
	sub._set_io_for_test(
		function(specs) { push(seen, "download:" + length(specs)); return 0; },
		function(path)  { push(seen, "read:" + path); return "vless://x@h:1\n"; }
	);
	// Exercise the seam: the injected reader returns our canned body.
	print(sub._read_raw_for_test("/tmp/whatever") + "\n");
	print(join(",", seen) + "\n");
')
echo "$out" | grep -q '^vless://x@h:1' \
	|| { echo "[$out]"; fail "S3-7: injected reader not used"; }
echo "$out" | grep -q 'read:/tmp/whatever' \
	|| { echo "[$out]"; fail "S3-7: reader hook not invoked with path"; }
pass "S3-7: injectable reader is wired through _set_io_for_test"

echo "ALL PASS"
