#!/bin/sh
# Unit-tests subscription.uc header parsing (subscription-userinfo + title).
set -eu
LIB="luci-singbox-ui/root/usr/share/singbox-ui"
UCODE="${UCODE_BIN:-ucode}"
command -v "$UCODE" >/dev/null 2>&1 || { echo "SKIP: no ucode"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/probe.uc" <<'UC'
let sub = require("subscription");
let hdr = "HTTP/2 200\r\n" +
  "content-type: text/plain\r\n" +
  "subscription-userinfo: upload=455; download=2576; total=107374182400; expire=1672502400\r\n" +
  "content-disposition: attachment; filename=\"My Sub\"\r\n\r\n";
print(sprintf("%J", sub._parse_headers_for_test(hdr)));
UC
out="$("$UCODE" -L "$LIB/lib" -L "$LIB" "$WORK/probe.uc")"
echo "$out" | grep -q '"total": 107374182400' || { echo "FAIL: total not parsed"; echo "$out"; exit 1; }
echo "$out" | grep -q '"expire": 1672502400'  || { echo "FAIL: expire not parsed"; echo "$out"; exit 1; }
echo "$out" | grep -q '"upload": 455'         || { echo "FAIL: upload not parsed"; echo "$out"; exit 1; }
echo "$out" | grep -q '"title": "My Sub"'     || { echo "FAIL: title not parsed"; echo "$out"; exit 1; }

# Missing headers → empty object, never an error.
cat > "$WORK/probe2.uc" <<'UC'
let sub = require("subscription");
let r = sub._parse_headers_for_test("HTTP/1.1 200 OK\r\nserver: x\r\n\r\n");
print(sprintf("%J", r));
UC
out2="$("$UCODE" -L "$LIB/lib" -L "$LIB" "$WORK/probe2.uc")"
echo "$out2" | grep -q 'userinfo' && { echo "FAIL: userinfo should be absent"; echo "$out2"; exit 1; } || true

# profile-title: base64-encoded value decodes; malformed base64 falls back to raw.
# parse_headers strips "base64:" only on a successful decode; on b64dec failure the
# `|| v` fallback keeps v unchanged — i.e. the full literal incl. the "base64:" prefix.
cat > "$WORK/probe_pt.uc" <<'UC'
let sub = require("subscription");
print(sprintf("%J", sub._parse_headers_for_test("profile-title: base64:SGVsbG8=\r\n")));
print("\n");
print(sprintf("%J", sub._parse_headers_for_test("profile-title: base64:@@@notb64@@@\r\n")));
print("\n");
UC
pt="$("$UCODE" -L "$LIB/lib" -L "$LIB" "$WORK/probe_pt.uc")"
echo "$pt" | grep -q '"title": "Hello"' || { echo "FAIL: base64 profile-title not decoded"; echo "$pt"; exit 1; }
# Malformed base64 must not throw and must keep the raw (undecoded) value verbatim.
echo "$pt" | grep -q '"title": "base64:@@@notb64@@@"' || { echo "FAIL: malformed base64 title not kept as raw"; echo "$pt"; exit 1; }

# cmd_sub_status picks up an existing .meta sidecar.
export UCI_CONFIG_DIR="$WORK/cfg"; mkdir -p "$UCI_CONFIG_DIR"
cat > "$UCI_CONFIG_DIR/singbox-ui" <<'UCI'
config outbound 'subM'
	option type 'subscription'
	option sub_url 'https://e/m'
UCI
mkdir -p "$WORK/run"
printf '%s' '{"title":"Hello","userinfo":{"total":100,"download":10}}' > "$WORK/run/sub_subM.meta"
printf 'vless://x@h:1\n' > "$WORK/run/sub_subM.txt"
cat > "$WORK/probe3.uc" <<UC
let sub = require("subscription");
let uci = require("uci").cursor("$UCI_CONFIG_DIR");
print(sprintf("%J", sub._cmd_sub_status_for_test(uci)));
UC
out3="$(SINGBOX_TMPDIR="$WORK/run" "$UCODE" -L "$LIB/lib" -L "$LIB" "$WORK/probe3.uc")"
echo "$out3" | grep -q '"title": "Hello"' || { echo "FAIL: status title"; echo "$out3"; exit 1; }
echo "$out3" | grep -q '"total": 100'     || { echo "FAIL: status userinfo"; echo "$out3"; exit 1; }
echo "PASS"
