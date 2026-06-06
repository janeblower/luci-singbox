#!/bin/sh
# tests/test_scrub_uc.sh
# Tests for lib/scrub.uc — secret masking
set -e
cd "$(dirname "$0")/.."

UCODE_PATH="luci-app-singbox-ui/root/usr/share/singbox-ui/lib"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Test 1: scrub_secrets masks top-level password
out=$(ucode -L "$UCODE_PATH/*.uc" -e '
  import { scrub_secrets } from "scrub";
  let r = scrub_secrets({ uuid: "abc", server: "1.1.1.1", port: 443 });
  print(r.uuid + "|" + r.server + "|" + r.port);
')
case "$out" in
    "***|1.1.1.1|443") echo "PASS: top-level uuid masked" ;;
    *) echo "FAIL: got '$out'"; exit 1 ;;
esac

# Test 2: scrub_secrets recurses into nested objects
out=$(ucode -L "$UCODE_PATH/*.uc" -e '
  import { scrub_secrets } from "scrub";
  let r = scrub_secrets({ tls: { reality: { private_key: "secret" } } });
  print(r.tls.reality.private_key);
')
[ "$out" = "***" ] && echo "PASS: nested private_key" || { echo "FAIL: got $out"; exit 1; }

# Test 3: scrub_secrets walks arrays (users[])
out=$(ucode -L "$UCODE_PATH/*.uc" -e '
  import { scrub_secrets } from "scrub";
  let r = scrub_secrets({ users: [{ name: "u1", password: "p1", uuid: "u-1" }] });
  print(r.users[0].name + "|" + r.users[0].password + "|" + r.users[0].uuid);
')
[ "$out" = "u1|***|***" ] && echo "PASS: users[] masked" || { echo "FAIL: got $out"; exit 1; }

# Test 4: scrub_secrets is idempotent
out=$(ucode -L "$UCODE_PATH/*.uc" -e '
  import { scrub_secrets } from "scrub";
  let r = scrub_secrets(scrub_secrets({ uuid: "abc" }));
  print(r.uuid);
')
[ "$out" = "***" ] && echo "PASS: idempotent" || { echo "FAIL: got $out"; exit 1; }

# Test 5: scrub_secrets preserves non-secret keys (path is NOT secret)
out=$(ucode -L "$UCODE_PATH/*.uc" -e '
  import { scrub_secrets } from "scrub";
  let r = scrub_secrets({ tls: { certificate_path: "/etc/cert.pem", key_path: "/etc/key.pem" } });
  print(r.tls.certificate_path + "|" + r.tls.key_path);
')
[ "$out" = "/etc/cert.pem|/etc/key.pem" ] && echo "PASS: paths preserved" || { echo "FAIL: got $out"; exit 1; }

# Test 6: scrub_secrets masks clash secret
out=$(ucode -L "$UCODE_PATH/*.uc" -e '
  import { scrub_secrets } from "scrub";
  let r = scrub_secrets({ experimental: { clash_api: { secret: "topsecret" } } });
  print(r.experimental.clash_api.secret);
')
[ "$out" = "***" ] && echo "PASS: clash secret masked" || { echo "FAIL: got $out"; exit 1; }

# Test 7: input is not mutated
out=$(ucode -L "$UCODE_PATH/*.uc" -e '
  import { scrub_secrets } from "scrub";
  let orig = { uuid: "abc" };
  scrub_secrets(orig);
  print(orig.uuid);
')
[ "$out" = "abc" ] && echo "PASS: input not mutated" || { echo "FAIL: got $out"; exit 1; }

echo "ALL PASS"
