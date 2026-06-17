#!/bin/sh
# tests/test_log_uc.sh
set -e
. "$(dirname "$0")/lib/sb_helpers.sh"
cd "$(dirname "$0")/.."

: "${UCODE_BIN:=$(command -v ucode)}"
[ -z "$UCODE_BIN" ] && { echo "SKIP: no ucode on host"; exit 0; }

UCODE_APP_LIB_DIR="${UCODE_APP_LIB_DIR:-$PWD/${SB_LIB}}"
run_uc() { "$UCODE_BIN" -L "$UCODE_APP_LIB_DIR" -e "$1"; }

echo "-- log_event captures key/value pairs via mockable logger"
out=$(run_uc '
	let log = require("log");
	let captured = [];
	log._set_logger_for_test(function(level, line) {
		push(captured, level + "|" + line);
	});
	log.log_event("info", "config.applied", { source: "rpcd", hash: "abc123" });
	for (let l in captured) print(l + "\n");
')
echo "$out" | grep -q '^info|.*event=config\.applied' \
	&& echo "  PASS: level+event prefix" \
	|| { echo "FAIL: [$out]"; exit 1; }
echo "$out" | grep -q 'source=rpcd' && echo "$out" | grep -q 'hash=abc123' \
	&& echo "  PASS: kv pairs emitted" \
	|| { echo "FAIL kv: [$out]"; exit 1; }
echo "$out" | grep -q 'ts=[0-9]' \
	&& echo "  PASS: timestamp present" \
	|| { echo "FAIL ts: [$out]"; exit 1; }

echo "-- log_event quotes values with whitespace"
out=$(run_uc '
	let log = require("log");
	let captured = [];
	log._set_logger_for_test(function(level, line) { push(captured, line); });
	log.log_event("warn", "x", { msg: "hello world" });
	print(captured[0] + "\n");
')
echo "$out" | grep -Eq 'msg="hello world"|msg="hello[^"]*"' \
	&& echo "  PASS: whitespace quoted" \
	|| { echo "FAIL: [$out]"; exit 1; }

echo "ALL PASS"
