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

# SEC-5: profile-title base64 — distinguish decode-FAILURE from empty-but-valid
# decode. A successful decode (even "") is honoured; only a hard b64dec failure
# falls back to the raw payload, and then WITHOUT the "base64:" prefix so the
# dashboard never renders a literal "base64:..." title.
cat > "$WORK/probe_pt.uc" <<'UC'
let sub = require("subscription");
print(sprintf("%J", sub._parse_headers_for_test("profile-title: base64:SGVsbG8=\r\n")));
print("\n");
print(sprintf("%J", sub._parse_headers_for_test("profile-title: base64:@@@notb64@@@\r\n")));
print("\n");
// empty-but-valid base64 -> decoded "" -> title omitted (NOT the raw "base64:" prefix)
print(sprintf("%J", sub._parse_headers_for_test("profile-title: base64:\r\n")));
print("\n");
UC
pt="$("$UCODE" -L "$LIB/lib" -L "$LIB" "$WORK/probe_pt.uc")"
echo "$pt" | grep -q '"title": "Hello"' || { echo "FAIL: base64 profile-title not decoded"; echo "$pt"; exit 1; }
# SEC-5: a malformed base64 must not throw, and the raw fallback must NOT carry
# the "base64:" prefix (the old `|| v` form leaked the literal prefix to the UI).
echo "$pt" | grep -q '"title": "@@@notb64@@@"'        || { echo "FAIL: SEC-5 malformed base64 should fall back to raw WITHOUT base64: prefix"; echo "$pt"; exit 1; }
echo "$pt" | grep -q '"title": "base64:@@@notb64@@@"' && { echo "FAIL: SEC-5 raw fallback still carries the base64: prefix"; echo "$pt"; exit 1; } || true
# SEC-5: empty-but-valid base64 decodes to "" → title key omitted entirely
# (parse_headers only sets title when non-empty), and certainly not "base64:".
echo "$pt" | grep -q '"title": "base64:"' && { echo "FAIL: SEC-5 empty base64 surfaced the prefix"; echo "$pt"; exit 1; } || true

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

# SEC-7: a refetch that yields NO userinfo/title headers must REMOVE a stale
# sub_<name>.meta sidecar left by a prior fetch — otherwise the dashboard keeps
# showing an expiry/quota/title that no longer applies. Drive cmd_fetch_subs
# through the injected fetcher: pass 1 emits a body + a profile-title header
# (meta written); pass 2 emits a body + a header dump with NO meta-bearing
# fields (meta must be dropped).
export UCI_CONFIG_DIR2="$WORK/cfg2"; mkdir -p "$UCI_CONFIG_DIR2"
cat > "$UCI_CONFIG_DIR2/singbox-ui" <<'UCI'
config outbound 'subS'
	option type 'subscription'
	option sub_url 'https://e/s'
UCI
META_PATH="$WORK/run2/sub_subS.meta"
cat > "$WORK/probe_sec7.uc" <<UC
let fs = require("fs");
let sub = require("subscription");
let uci = require("uci").cursor("$UCI_CONFIG_DIR2");
// Pass 1: body + a profile-title header → meta sidecar should be written.
sub._set_fetcher_for_test(function(jobs){
	for (let j in jobs) {
		let b = fs.open(j.body_path, "w"); b.write("vless://x\@h:1#n\n"); b.close();
		let h = fs.open(j.hdr_path, "w");
		h.write("HTTP/2 200\r\nprofile-title: First Title\r\nsubscription-userinfo: upload=1; download=2; total=3; expire=4\r\n\r\n");
		h.close();
	}
});
sub._cmd_fetch_subs_for_test(uci);
let m1 = fs.stat("$META_PATH");
print("after_pass1_meta_exists=", (m1 != null) ? "yes" : "no"); print("\n");
// Pass 2: body but a header dump with NO userinfo/title → stale meta must go.
sub._set_fetcher_for_test(function(jobs){
	for (let j in jobs) {
		let b = fs.open(j.body_path, "w"); b.write("vless://x\@h:1#n\n"); b.close();
		let h = fs.open(j.hdr_path, "w");
		h.write("HTTP/2 200\r\nserver: nginx\r\n\r\n");
		h.close();
	}
});
sub._cmd_fetch_subs_for_test(uci);
let m2 = fs.stat("$META_PATH");
print("after_pass2_meta_exists=", (m2 != null) ? "yes" : "no"); print("\n");
UC
mkdir -p "$WORK/run2"
sec7="$(SINGBOX_TMPDIR="$WORK/run2" "$UCODE" -L "$LIB/lib" -L "$LIB" "$WORK/probe_sec7.uc")"
echo "$sec7" | grep -q 'after_pass1_meta_exists=yes' || { echo "FAIL: SEC-7 pass1 should have written meta sidecar"; echo "$sec7"; exit 1; }
echo "$sec7" | grep -q 'after_pass2_meta_exists=no'  || { echo "FAIL: SEC-7 stale meta sidecar not removed on header-less refetch"; echo "$sec7"; exit 1; }

echo "PASS"
