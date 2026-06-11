#!/bin/sh
# tests/test_protocol_emit.sh — drives generate.uc with the fixture UCI
# files under tests/fixtures/protocols/ and asserts the emitted JSON.
# Each fixture is paired with a <name>.expect file containing a ucode
# boolean expression evaluated against the generated config (bound as `c`).
#
# Adapted from tests/test_outbound_constructor.sh — same harness shape, just
# walking a fixture directory instead of inline UCI text.
set -e
cd "$(dirname "$0")/.."

if command -v ucode >/dev/null 2>&1; then
	UCODE_BIN=ucode
	UCODE_LIB_FLAGS="-L ${UCODE_APP_LIB_DIR:-$PWD/luci-singbox-ui/root/usr/share/singbox-ui/lib}"
elif [ -x "${UCODE_BIN:-}" ] && [ -d "${UCODE_STUB_DIR:-}" ]; then
	UCODE_LIB_FLAGS="-L $UCODE_STUB_DIR -L ${UCODE_APP_LIB_DIR:-$PWD/luci-singbox-ui/root/usr/share/singbox-ui/lib}"
	[ -n "${UCODE_LIB_DIR:-}" ] && UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L $UCODE_LIB_DIR"
else
	echo "SKIP test_protocol_emit (ucode missing)"; exit 0
fi

FIXTURES=tests/fixtures/protocols
[ -d "$FIXTURES" ] || { echo "PASS: no fixtures yet"; exit 0; }

GENERATE_UC=luci-singbox-ui/root/usr/share/singbox-ui/generate.uc
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
SANDBOX_DIR="$WORK/sandbox"; mkdir -p "$SANDBOX_DIR/subs"

fail=0
for uci_file in "$FIXTURES"/*.uci; do
	[ -e "$uci_file" ] || continue
	name=$(basename "$uci_file" .uci)
	expect_file="$FIXTURES/$name.expect"
	if [ ! -f "$expect_file" ]; then
		echo "SKIP $name (no .expect)"; continue
	fi
	# Stage UCI into per-test config dir.
	test_dir="$WORK/$name"
	mkdir -p "$test_dir"
	cp "$uci_file" "$test_dir/singbox-ui"
	# Generate config.json.
	out_file="$SANDBOX_DIR/singbox-ui.json"
	# shellcheck disable=SC2086
	if ! UCI_CONFIG_DIR="$test_dir" SINGBOX_TMPDIR="$SANDBOX_DIR/subs" SINGBOX_CONFIG="$out_file" \
		"$UCODE_BIN" $UCODE_LIB_FLAGS "$GENERATE_UC" >"$test_dir/gen.log" 2>&1; then
		echo "FAIL: $name — generate.uc crashed"
		cat "$test_dir/gen.log"; fail=1; continue
	fi
	# Evaluate the .expect expression against the resulting JSON.
	expr=$(cat "$expect_file")
	# shellcheck disable=SC2086
	ok=$("$UCODE_BIN" $UCODE_LIB_FLAGS -e "
		let fs = require('fs');
		let c = json(fs.readfile('$out_file'));
		print(($expr) ? 'OK' : 'BAD');
	" 2>&1)
	if [ "$ok" = "OK" ]; then
		echo "PASS: $name"
	else
		echo "FAIL: $name (assertion: $expr)"
		cat "$out_file" 2>/dev/null || true; fail=1
	fi
done

[ "$fail" -eq 0 ] || exit 1
echo "ALL PASS: test_protocol_emit"
