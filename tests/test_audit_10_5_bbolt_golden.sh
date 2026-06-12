#!/bin/sh
# tests/test_audit_10_5_bbolt_golden.sh
#
# Wires the bbolt-client golden suite (bbolt-client/test.sh) into the main
# tests/run.sh run (audit 10.5).
#
# Before this, bbolt-client/test.sh ran ONLY in the separate
# .github/workflows/bbolt-client.yml job. The parser's golden checks (whole-
# tree parity, -r unwrap, adversarial clean-exit, forged-field bounds) never
# ran in the SAME pass as the ucode consumer tests, so a behavioural mismatch
# between the real Rust binary's `-r` output and the stub used by
# test_rs_cache_extract.sh (SINGBOX_BBOLT_BIN stub) would pass BOTH suites.
#
# This shim exercises the REAL built binary end-to-end against the frozen
# testdata/cache.db golden, closing the stub-vs-real gap. It is gated on the
# binary actually being BUILT — when it is absent (the common case: the binary
# is not packaged, it's downloaded at runtime, and `cargo build` is a heavy
# per-arch step that the integration VM does not run) it SKIPs cleanly. The
# bbolt-client.yml workflow still runs the full cross-arch matrix; this is the
# integration-pass smoke that catches a real-vs-stub drift early when a dev
# happens to have a local build.
set -e
cd "$(dirname "$0")/.."

BBOLT_DIR=bbolt-client
# RUN is what bbolt-client/test.sh invokes. Allow an override (e.g. a cross
# binary under qemu, mirroring the workflow's RUN=) but default to the native
# build the suite itself defaults to.
BIN="${BBOLT_TEST_BIN:-$BBOLT_DIR/bbolt-client-rs}"

if [ ! -d "$BBOLT_DIR" ]; then
	echo "SKIP test_audit_10_5_bbolt_golden: $BBOLT_DIR not present in tree"
	exit 0
fi
if [ ! -x "$BIN" ]; then
	echo "SKIP test_audit_10_5_bbolt_golden: real bbolt binary not built ($BIN)"
	echo "      (build it with bbolt-client/build.sh to exercise the parser here;"
	echo "       the cross-arch golden matrix still runs in bbolt-client.yml)"
	exit 0
fi
if [ ! -f "$BBOLT_DIR/testdata/cache.db" ]; then
	echo "SKIP test_audit_10_5_bbolt_golden: golden testdata missing"
	exit 0
fi

echo "-- bbolt-client golden suite (real parser, end-to-end) via $BIN"
# Run the self-contained golden suite against the real binary. It compares the
# binary's whole-tree + `-r` output against frozen sha256 goldens and asserts
# clean exits on adversarial/forged inputs, so a regression in the real
# parser's output (the exact thing the ucode-side stub cannot catch) fails here.
RUN="$(pwd)/$BIN" sh "$BBOLT_DIR/test.sh"

echo "OK"
