#!/bin/sh
# tests/test_scrub_uc.sh
# Tests for lib/scrub.uc — secret masking
set -e
if command -v ucode >/dev/null 2>&1; then
	UCODE_BIN=ucode; UCODE_LIB_FLAGS="-L ${UCODE_APP_LIB_DIR:-$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/lib}"
elif [ -x "${UCODE_BIN:-}" ] && [ -d "${UCODE_STUB_DIR:-}" ]; then
	UCODE_LIB_FLAGS="-L $UCODE_STUB_DIR -L ${UCODE_APP_LIB_DIR:-$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/lib}"
	[ -n "${UCODE_LIB_DIR:-}" ] && UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L $UCODE_LIB_DIR"
else echo "SKIP: ucode not available"; exit 0; fi

# Test 1: scrub_secrets masks top-level uuid
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS -e '
  let scrub = require("scrub");
  let r = scrub.scrub_secrets({ uuid: "abc", server: "1.1.1.1", port: 443 });
  print(r.uuid + "|" + r.server + "|" + r.port);
')
case "$out" in
    "***|1.1.1.1|443") echo "PASS: top-level uuid masked" ;;
    *) echo "FAIL: got '$out'"; exit 1 ;;
esac

# Test 2: scrub_secrets recurses into nested objects
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS -e '
  let scrub = require("scrub");
  let r = scrub.scrub_secrets({ tls: { reality: { private_key: "secret" } } });
  print(r.tls.reality.private_key);
')
[ "$out" = "***" ] && echo "PASS: nested private_key" || { echo "FAIL: got $out"; exit 1; }

# Test 3: scrub_secrets walks arrays (users[])
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS -e '
  let scrub = require("scrub");
  let r = scrub.scrub_secrets({ users: [{ name: "u1", password: "p1", uuid: "u-1" }] });
  print(r.users[0].name + "|" + r.users[0].password + "|" + r.users[0].uuid);
')
[ "$out" = "u1|***|***" ] && echo "PASS: users[] masked" || { echo "FAIL: got $out"; exit 1; }

# Test 4: scrub_secrets is idempotent
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS -e '
  let scrub = require("scrub");
  let r = scrub.scrub_secrets(scrub.scrub_secrets({ uuid: "abc" }));
  print(r.uuid);
')
[ "$out" = "***" ] && echo "PASS: idempotent" || { echo "FAIL: got $out"; exit 1; }

# Test 5: scrub_secrets preserves non-secret keys (path is NOT secret)
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS -e '
  let scrub = require("scrub");
  let r = scrub.scrub_secrets({ tls: { certificate_path: "/etc/cert.pem", key_path: "/etc/key.pem" } });
  print(r.tls.certificate_path + "|" + r.tls.key_path);
')
[ "$out" = "/etc/cert.pem|/etc/key.pem" ] && echo "PASS: paths preserved" || { echo "FAIL: got $out"; exit 1; }

# Test 6: scrub_secrets masks clash secret
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS -e '
  let scrub = require("scrub");
  let r = scrub.scrub_secrets({ experimental: { clash_api: { secret: "topsecret" } } });
  print(r.experimental.clash_api.secret);
')
[ "$out" = "***" ] && echo "PASS: clash secret masked" || { echo "FAIL: got $out"; exit 1; }

# Test 7: input is not mutated
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS -e '
  let scrub = require("scrub");
  let orig = { uuid: "abc" };
  scrub.scrub_secrets(orig);
  print(orig.uuid);
')
[ "$out" = "abc" ] && echo "PASS: input not mutated" || { echo "FAIL: got $out"; exit 1; }

# Test 8: reality public_key and short_id are masked (spec C1.1)
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS -e '
  let scrub = require("scrub");
  let r = scrub.scrub_secrets({ tls: { reality: { public_key: "x", short_id: "y" } } });
  print(r.tls.reality.public_key + "|" + r.tls.reality.short_id);
')
[ "$out" = "***|***" ] && echo "PASS: reality public_key+short_id masked" || { echo "FAIL: got $out"; exit 1; }

# Test 9: inline cert_pem is masked (spec C1.1)
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS -e '
  let scrub = require("scrub");
  let r = scrub.scrub_secrets({ tls: { cert_pem: "BEGIN CERT..." } });
  print(r.tls.cert_pem);
')
[ "$out" = "***" ] && echo "PASS: cert_pem masked" || { echo "FAIL: got $out"; exit 1; }

# Test 10: certificate_path (path, not content) is NOT masked
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS -e '
  let scrub = require("scrub");
  let r = scrub.scrub_secrets({ tls: { certificate_path: "/etc/cert.pem" } });
  print(r.tls.certificate_path);
')
[ "$out" = "/etc/cert.pem" ] && echo "PASS: certificate_path preserved" || { echo "FAIL: got $out"; exit 1; }

# Test 11: deep-nested secret (depth 4) is masked
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS -e '
  let scrub = require("scrub");
  let r = scrub.scrub_secrets({ a: { b: { c: { uuid: "x" } } } });
  print(r.a.b.c.uuid);
')
[ "$out" = "***" ] && echo "PASS: deep-nested uuid masked" || { echo "FAIL: got $out"; exit 1; }

# Test 12: arrays of strings pass through unchanged
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS -e '
  let scrub = require("scrub");
  let r = scrub.scrub_secrets({ tags: ["a", "b"] });
  print(r.tags[0] + "|" + r.tags[1]);
')
[ "$out" = "a|b" ] && echo "PASS: string array unchanged" || { echo "FAIL: got $out"; exit 1; }

echo "ALL PASS"
