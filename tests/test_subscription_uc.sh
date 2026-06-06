#!/bin/sh
# tests/test_subscription_uc.sh
# Drives subscription.uc with a fake curl on PATH and a synthetic UCI dir.
set -e

# Mirror test_generate.sh: skip if ucode/uci-mod unavailable on dev box.
if command -v ucode >/dev/null 2>&1; then
	UCODE_BIN=ucode
	UCODE_LIB_FLAGS="-L ${UCODE_APP_LIB_DIR:-$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/lib}"
elif [ -x "${UCODE_BIN:-}" ] && [ -d "${UCODE_STUB_DIR:-}" ]; then
	UCODE_LIB_FLAGS="-L $UCODE_STUB_DIR"
	[ -n "${UCODE_LIB_DIR:-}" ] && UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L $UCODE_LIB_DIR"
	UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L ${UCODE_APP_LIB_DIR:-$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/lib}"
else
	echo "SKIP: ucode not available"
	exit 0
fi

SUB_UC=luci-app-singbox-ui/root/usr/share/singbox-ui/subscription.uc
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Sandboxed tmp dir for the script's outputs.
export SINGBOX_TMPDIR="$TMPDIR/runtime"
mkdir -p "$SINGBOX_TMPDIR"

# Fake curl: writes the contents of $FAKE_CURL_BODY_FILE to the -o argument,
# and records its full argv to $FAKE_CURL_LOG for assertions.
mkdir -p "$TMPDIR/bin"
cat >"$TMPDIR/bin/curl" <<'EOF'
#!/bin/sh
echo "$@" >>"${FAKE_CURL_LOG:-/dev/null}"
out=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		*)  shift ;;
	esac
done
[ -n "$out" ] && cp "${FAKE_CURL_BODY_FILE:-/dev/null}" "$out"
exit 0
EOF
chmod +x "$TMPDIR/bin/curl"
export PATH="$TMPDIR/bin:$PATH"
export FAKE_CURL_LOG="$TMPDIR/curl.log"

pass() { echo "  PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

run_uc() {
	# shellcheck disable=SC2086
	UCI_CONFIG_DIR="$TMPDIR" "$UCODE_BIN" $UCODE_LIB_FLAGS "$SUB_UC" "$@"
}

echo "-- stub foreach(null) returns all sections"
cat >"$TMPDIR/singbox-ui" <<'EOF'
config outbound 'a'
	option type 'subscription'
config outbound 'b'
	option type 'interface'
EOF
# Drive a tiny ucode probe through the same loader to verify foreach(null).
cat >"$TMPDIR/probe.uc" <<'EOF'
let uci = require("uci").cursor(getenv("UCI_CONFIG_DIR"));
let n = 0;
uci.foreach("singbox-ui", null, function (s) { n++; });
print(n);
EOF
# shellcheck disable=SC2086
out=$(UCI_CONFIG_DIR="$TMPDIR" "$UCODE_BIN" $UCODE_LIB_FLAGS "$TMPDIR/probe.uc")
[ "$out" = "2" ] || fail "expected 2 sections via foreach(null), got '$out'"
pass "foreach(null) yields all sections"

# ---- fetch-subs with base64 body ----
echo "-- fetch-subs decodes base64 body and writes sub_<name>.txt"
cat >"$TMPDIR/singbox-ui" <<'EOF'
config outbound 'subA'
	option type 'subscription'
	option sub_url 'https://example.test/sub'
EOF
# base64("vless://uuid@host:443?security=tls#A\n")
printf '%s' 'dmxlc3M6Ly91dWlkQGhvc3Q6NDQzP3NlY3VyaXR5PXRscyNBCg==' >"$TMPDIR/body"
export FAKE_CURL_BODY_FILE="$TMPDIR/body"
: >"$FAKE_CURL_LOG"

run_uc fetch-subs

[ -s "$SINGBOX_TMPDIR/sub_subA.txt" ] || fail "sub_subA.txt missing or empty"
grep -q '^vless://uuid@host:443' "$SINGBOX_TMPDIR/sub_subA.txt" \
	|| { echo "got:"; cat "$SINGBOX_TMPDIR/sub_subA.txt"; fail "decoded URL not found"; }
pass "base64 body decoded"

# ---- default UA is Mozilla-flavoured ----
echo "-- default User-Agent passed to curl starts with Mozilla/5.0"
grep -q -- '-A Mozilla/5.0' "$FAKE_CURL_LOG" \
	|| { echo "curl.log:"; cat "$FAKE_CURL_LOG"; fail "-A Mozilla/5.0 not in curl argv"; }
pass "Mozilla UA used"

# ---- fetch-subs with plain (non-base64) body ----
echo "-- fetch-subs accepts plain-text body when base64 decode is empty"
printf '%s\n' 'trojan://pwd@host:443#B' >"$TMPDIR/body"
rm -f "$SINGBOX_TMPDIR/sub_subA.txt"
run_uc fetch-subs
grep -q '^trojan://' "$SINGBOX_TMPDIR/sub_subA.txt" || fail "plain body not written"
pass "plain body passthrough"

# ---- fetch-rulesets: local source copy ----
echo "-- fetch-rulesets copies local .json source to rs_<name>.json"
mkdir -p "$TMPDIR/src"
printf '%s' '{"version":1,"rules":[]}' >"$TMPDIR/src/r.json"
cat >"$TMPDIR/singbox-ui" <<EOF
config ruleset 'rA'
	option type 'local'
	option path '$TMPDIR/src/r.json'
	option nft_rules '1'
EOF
run_uc fetch-rulesets
[ -s "$SINGBOX_TMPDIR/rs_rA.json" ] || fail "rs_rA.json missing"
grep -q '"rules"' "$SINGBOX_TMPDIR/rs_rA.json" || fail "rs_rA.json content wrong"
pass "local source ruleset"

# ---- SINGBOX_BOOT_FETCH=1 shortens timeout ----
echo "-- SINGBOX_BOOT_FETCH=1 uses --max-time 5 for subs"
cat >"$TMPDIR/singbox-ui" <<'EOF'
config outbound 'subA'
	option type 'subscription'
	option sub_url 'https://example.test/sub'
EOF
printf '%s' 'dmxlc3M6Ly91dWlkQGhvc3Q6NDQzCg==' >"$TMPDIR/body"
: >"$FAKE_CURL_LOG"
SINGBOX_BOOT_FETCH=1 run_uc fetch-subs
grep -q -- '--max-time 5' "$FAKE_CURL_LOG" \
    || { echo "curl.log:"; cat "$FAKE_CURL_LOG"; fail "--max-time 5 missing in boot mode"; }
pass "boot mode shortens timeout to 5s"

# ---- parallel curl ----
echo "-- two subscriptions are fetched in parallel"
# Replace curl stub with one that sleeps 2s and records timestamp.
cat >"$TMPDIR/bin/curl" <<'EOF'
#!/bin/sh
date +%s%N >>"${FAKE_CURL_LOG:-/dev/null}"
sleep 2
echo "$@" >>"${FAKE_CURL_LOG:-/dev/null}"
out=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        *)  shift ;;
    esac
done
[ -n "$out" ] && cp "${FAKE_CURL_BODY_FILE:-/dev/null}" "$out"
exit 0
EOF
chmod +x "$TMPDIR/bin/curl"
cat >"$TMPDIR/singbox-ui" <<'EOF'
config outbound 'subA'
	option type 'subscription'
	option sub_url 'https://example.test/a'
config outbound 'subB'
	option type 'subscription'
	option sub_url 'https://example.test/b'
EOF
printf '%s' 'dmxlc3M6Ly91dWlkQGhvc3Q6NDQzCg==' >"$TMPDIR/body"
: >"$FAKE_CURL_LOG"
start=$(date +%s)
run_uc fetch-subs
end=$(date +%s)
elapsed=$((end - start))
# Sequential = ~4s, parallel = ~2s. Allow some headroom.
[ "$elapsed" -lt 4 ] || fail "expected parallel (<4s), got ${elapsed}s"
pass "two curls run in parallel (${elapsed}s)"

# Restore the simple stub for following tests.
cat >"$TMPDIR/bin/curl" <<'EOF'
#!/bin/sh
echo "$@" >>"${FAKE_CURL_LOG:-/dev/null}"
out=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        *)  shift ;;
    esac
done
[ -n "$out" ] && cp "${FAKE_CURL_BODY_FILE:-/dev/null}" "$out"
exit 0
EOF
chmod +x "$TMPDIR/bin/curl"

# ---- failed curl preserves existing sub_*.txt ----
echo "-- failed curl does not clobber existing sub_<name>.txt"
cat >"$TMPDIR/singbox-ui" <<'EOF'
config outbound 'subA'
	option type 'subscription'
	option sub_url 'https://example.test/sub'
EOF
# Seed an existing sub_subA.txt
mkdir -p "$SINGBOX_TMPDIR"
printf 'vless://kept@host:1\n' >"$SINGBOX_TMPDIR/sub_subA.txt"
# Curl stub returns failure.
cat >"$TMPDIR/bin/curl" <<'EOF'
#!/bin/sh
exit 22
EOF
chmod +x "$TMPDIR/bin/curl"
run_uc fetch-subs
grep -q '^vless://kept@host:1' "$SINGBOX_TMPDIR/sub_subA.txt" \
    || fail "cached sub_subA.txt was clobbered by failed curl"
pass "cache preserved on curl failure"
# Restore curl stub.
cat >"$TMPDIR/bin/curl" <<'EOF'
#!/bin/sh
echo "$@" >>"${FAKE_CURL_LOG:-/dev/null}"
out=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        *)  shift ;;
    esac
done
[ -n "$out" ] && cp "${FAKE_CURL_BODY_FILE:-/dev/null}" "$out"
exit 0
EOF
chmod +x "$TMPDIR/bin/curl"

# ---- refresh: no-op when fresh, runs when stale, runs with force ----
echo "-- refresh respects mtime"
cat >"$TMPDIR/singbox-ui" <<EOF
config outbound 'subA'
	option type 'subscription'
	option sub_url 'https://example.test/sub'
	option sub_interval '3600'
EOF
printf '%s' 'dmxlc3M6Ly91dWlkQGhvc3Q6NDQzCg==' >"$TMPDIR/body"
run_uc fetch-subs                                  # warm cache
old_mt=$(F="$SINGBOX_TMPDIR/sub_subA.txt" "$UCODE_BIN" -e 'let s=require("fs").stat(getenv("F")); print(s ? s.mtime : 0)')
sleep 1
: >"$FAKE_CURL_LOG"
SINGBOX_NO_RELOAD=1 run_uc refresh subscriptions   # fresh → no-op
new_mt=$(F="$SINGBOX_TMPDIR/sub_subA.txt" "$UCODE_BIN" -e 'let s=require("fs").stat(getenv("F")); print(s ? s.mtime : 0)')
[ "$old_mt" = "$new_mt" ] || fail "fresh refresh re-downloaded"
[ ! -s "$FAKE_CURL_LOG" ] || fail "fresh refresh called curl"
pass "fresh refresh is no-op"

SINGBOX_NO_RELOAD=1 run_uc refresh subscriptions force
[ -s "$FAKE_CURL_LOG" ] || fail "forced refresh did not call curl"
pass "forced refresh re-downloads"

# ---- regression: tproxy inbound with nft_rules='1' must NOT trigger a
# ruleset refresh. Pre-fix any_rulesets_stale() walked every section that had
# `nft_rules='1'`, including tproxy inbounds, whose rs_<name>.json never
# exists — so the cron loop reloaded sing-box every 30 minutes for nothing.
echo "-- inbound nft_rules='1' is not treated as a ruleset"
cat >"$TMPDIR/singbox-ui" <<'EOF'
config inbound 'tproxy_in'
	option enabled '1'
	option protocol 'tproxy'
	option listen_port '7893'
	option nft_rules '1'
EOF
: >"$FAKE_CURL_LOG"
SINGBOX_NO_RELOAD=1 run_uc refresh rulesets force
[ ! -s "$FAKE_CURL_LOG" ] || { echo "curl.log:"; cat "$FAKE_CURL_LOG"; fail "ruleset refresh fired on inbound"; }
pass "inbound nft_rules='1' ignored by ruleset refresh"

# ---- sub_update_via outbound: curl --interface receives the resolved netdev,
# not the UCI logical name. helpers.resolve_iface_device honours
# SINGBOX_DEV_<iface> so this test can pin the translation.
echo "-- sub_update_via outbound resolves UCI iface to real netdev"
cat >"$TMPDIR/singbox-ui" <<'EOF'
config outbound 'via_wan'
	option type 'interface'
	option interface 'wan'
config outbound 'subA'
	option type 'subscription'
	option sub_url 'https://example.test/sub'
	option sub_update_via 'via_wan'
EOF
printf '%s' 'dmxlc3M6Ly91dWlkQGhvc3Q6NDQzCg==' >"$TMPDIR/body"
: >"$FAKE_CURL_LOG"
SINGBOX_DEV_wan='pppoe-wan' run_uc fetch-subs
grep -q -- '--interface pppoe-wan' "$FAKE_CURL_LOG" \
	|| { echo "curl.log:"; cat "$FAKE_CURL_LOG"; fail "expected --interface pppoe-wan"; }
pass "sub_update_via resolves to pppoe-wan"

# ---- share-link parsers (Phase B7): vmess://, ss://, trojan:// ----
# A small probe imports lib/outbound.uc and prints the JSON the dispatcher
# would feed into the outbound array for a given URL.
cat >"$TMPDIR/parse_probe.uc" <<'EOF'
let outbound = require("outbound");
let url = ARGV[0];
let parsed = outbound.parse_proxy_url(url);
print(parsed == null ? "null" : sprintf("%J", parsed));
EOF

run_probe() {
	# shellcheck disable=SC2086
	"$UCODE_BIN" $UCODE_LIB_FLAGS "$TMPDIR/parse_probe.uc" "$1"
}

echo "-- parse_vmess: v2rayN base64-JSON form"
# base64 of: {"v":"2","ps":"v-test","add":"v.example.com","port":443,
#             "id":"550e8400-e29b-41d4-a716-446655440000","aid":0,"tls":"tls"}
VMESS_OK='vmess://eyJ2IjoiMiIsInBzIjoidi10ZXN0IiwiYWRkIjoidi5leGFtcGxlLmNvbSIsInBvcnQiOjQ0MywiaWQiOiI1NTBlODQwMC1lMjliLTQxZDQtYTcxNi00NDY2NTU0NDAwMDAiLCJhaWQiOjAsInRscyI6InRscyJ9'
out=$(run_probe "$VMESS_OK")
echo "$out" | grep -q '"type":[[:space:]]*"vmess"'            || { echo "$out"; fail "vmess type"; }
echo "$out" | grep -q '"server":[[:space:]]*"v.example.com"'  || { echo "$out"; fail "vmess server"; }
echo "$out" | grep -q '"server_port":[[:space:]]*443'         || { echo "$out"; fail "vmess port"; }
echo "$out" | grep -q '"uuid":[[:space:]]*"550e8400-e29b-41d4-a716-446655440000"' || { echo "$out"; fail "vmess uuid"; }
echo "$out" | grep -q '"enabled":[[:space:]]*true'            || { echo "$out"; fail "vmess tls.enabled"; }
# aid: 0 → must NOT emit alter_id
echo "$out" | grep -q 'alter_id' && { echo "$out"; fail "vmess alter_id leaked on aid=0"; }
pass "parse_vmess accepts v2rayN base64-JSON URL"

echo "-- parse_vmess: invalid base64 → null"
out=$(run_probe 'vmess://!!!not-base64!!!')
# build_outbounds returns no outbound when parse fails → probe prints "null".
echo "$out" | grep -q '^null$' || { echo "$out"; fail "vmess invalid: expected null"; }
pass "parse_vmess rejects malformed payload"

echo "-- parse_ss: plain method:password@host:port#name"
out=$(run_probe 'ss://aes-256-gcm:test-pw@s.example.com:8388#myname')
echo "$out" | grep -q '"type":[[:space:]]*"shadowsocks"'      || { echo "$out"; fail "ss type"; }
echo "$out" | grep -q '"server":[[:space:]]*"s.example.com"'  || { echo "$out"; fail "ss server"; }
echo "$out" | grep -q '"server_port":[[:space:]]*8388'        || { echo "$out"; fail "ss port"; }
echo "$out" | grep -q '"method":[[:space:]]*"aes-256-gcm"'    || { echo "$out"; fail "ss method"; }
echo "$out" | grep -q '"password":[[:space:]]*"test-pw"'      || { echo "$out"; fail "ss password"; }
pass "parse_ss accepts plain method:password URL"

echo "-- parse_ss: legacy base64(method:password)@host:port"
# base64("aes-256-gcm:test-pw") = "YWVzLTI1Ni1nY206dGVzdC1wdw=="
out=$(run_probe 'ss://YWVzLTI1Ni1nY206dGVzdC1wdw==@s.example.com:8388#myname')
echo "$out" | grep -q '"method":[[:space:]]*"aes-256-gcm"'    || { echo "$out"; fail "ss b64 method"; }
echo "$out" | grep -q '"password":[[:space:]]*"test-pw"'      || { echo "$out"; fail "ss b64 password"; }
pass "parse_ss accepts legacy base64 userinfo"

echo "-- parse_ss: missing port → null"
out=$(run_probe 'ss://aes-256-gcm:test-pw@s.example.com')
echo "$out" | grep -q '^null$' || { echo "$out"; fail "ss invalid: expected null"; }
pass "parse_ss rejects URL without port"

echo "-- parse_trojan: full URL with sni"
out=$(run_probe 'trojan://trojan-pw@t.example.com:443?sni=t.example.com#myname')
echo "$out" | grep -q '"type":[[:space:]]*"trojan"'           || { echo "$out"; fail "trojan type"; }
echo "$out" | grep -q '"server":[[:space:]]*"t.example.com"'  || { echo "$out"; fail "trojan server"; }
echo "$out" | grep -q '"server_port":[[:space:]]*443'         || { echo "$out"; fail "trojan port"; }
echo "$out" | grep -q '"password":[[:space:]]*"trojan-pw"'    || { echo "$out"; fail "trojan password"; }
echo "$out" | grep -q '"server_name":[[:space:]]*"t.example.com"' || { echo "$out"; fail "trojan sni"; }
echo "$out" | grep -q '"enabled":[[:space:]]*true'            || { echo "$out"; fail "trojan tls.enabled"; }
pass "parse_trojan accepts canonical URL"

echo "-- parse_trojan: no host:port → null"
out=$(run_probe 'trojan://trojan-pw@')
echo "$out" | grep -q '^null$' || { echo "$out"; fail "trojan invalid: expected null"; }
pass "parse_trojan rejects URL without host:port"

# ---- share-link sanitizer (Phase C1 Task 6) ----
# Hostile subscription servers should not be able to inject control chars
# (NUL/CR/LF/TAB) or non-host bytes into UCI-stored fields. The sanitizers
# in lib/outbound.uc (url_decode, safe_tag, safe_host, safe_port) defend
# the parsers against such payloads. These tests verify each defense path.

echo "-- url_decode strips control chars from ss password"
# password contains %00 (NUL), %0a (LF), %09 (TAB); letters in between survive.
out=$(run_probe 'ss://aes-256-gcm:pa%00ss%0aword%09end@1.2.3.4:8443#san')
echo "$out" | grep -q '"password":[[:space:]]*"passwordend"' \
	|| { echo "$out"; fail "ss password not scrubbed: expected 'passwordend'"; }
pass "ss password control chars dropped by url_decode"

echo "-- parse_trojan: control chars in password are dropped"
# trojan://pw%0aevil@h.example.com:443 → password === "pwevil"
out=$(run_probe 'trojan://pw%0aevil@h.example.com:443#san')
echo "$out" | grep -q '"password":[[:space:]]*"pwevil"' \
	|| { echo "$out"; fail "trojan password not scrubbed: expected 'pwevil'"; }
pass "trojan password control chars dropped"

echo "-- parse_vmess: tag with control chars is sanitized to imported-<hex>"
# base64 of: {"v":"2","ps":"my\nevil","add":"v.example.com","port":443,
#             "id":"550e8400-e29b-41d4-a716-446655440000","aid":0}
VMESS_BAD_TAG='vmess://eyJ2IjoiMiIsInBzIjoibXlcbmV2aWwiLCJhZGQiOiJ2LmV4YW1wbGUuY29tIiwicG9ydCI6NDQzLCJpZCI6IjU1MGU4NDAwLWUyOWItNDFkNC1hNzE2LTQ0NjY1NTQ0MDAwMCIsImFpZCI6MH0='
out=$(run_probe "$VMESS_BAD_TAG")
# tag must NOT contain a literal newline; must match the fallback form.
echo "$out" | grep -qE '"tag":[[:space:]]*"imported-[0-9a-f]{8}"' \
	|| { echo "$out"; fail "vmess tag not sanitized to imported-<hex>"; }
pass "vmess tag with newline replaced by imported-<hex>"

echo "-- parse_vmess: server with non-host bytes → null"
# base64 of: {"v":"2","ps":"x","add":"v.example.com\n","port":443,"id":"u","aid":0}
VMESS_BAD_HOST='vmess://eyJ2IjoiMiIsInBzIjoieCIsImFkZCI6InYuZXhhbXBsZS5jb21cbiIsInBvcnQiOjQ0MywiaWQiOiJ1IiwiYWlkIjowfQ=='
out=$(run_probe "$VMESS_BAD_HOST")
echo "$out" | grep -q '^null$' || { echo "$out"; fail "vmess: bad host should return null"; }
pass "parse_vmess rejects host with non-host bytes"

echo "-- parse_hy2: port out of range → null"
out=$(run_probe 'hy2://pw@h.example.com:99999')
echo "$out" | grep -q '^null$' || { echo "$out"; fail "hy2: port 99999 should return null"; }
out=$(run_probe 'hy2://pw@h.example.com:0')
echo "$out" | grep -q '^null$' || { echo "$out"; fail "hy2: port 0 should return null"; }
pass "parse_hy2 rejects port out of 1..65535"

echo "-- parse_hy2: password control chars are dropped"
out=$(run_probe 'hy2://pw%00boom@h.example.com:443')
echo "$out" | grep -q '"password":[[:space:]]*"pwboom"' \
	|| { echo "$out"; fail "hy2 password not scrubbed: expected 'pwboom'"; }
pass "hy2 password control chars dropped"

echo "-- parse_vless: port out of range → null"
out=$(run_probe 'vless://u@h.example.com:70000')
echo "$out" | grep -q '^null$' || { echo "$out"; fail "vless: port 70000 should return null"; }
pass "parse_vless rejects port > 65535"

echo "-- safe_tag fallback is deterministic and matches ^imported-[0-9a-f]{8}\$"
# Run twice with same hostile input; tags should be byte-identical (FNV-1a is
# stable). The fallback shape is also explicitly verified.
out1=$(run_probe "$VMESS_BAD_TAG")
out2=$(run_probe "$VMESS_BAD_TAG")
[ "$out1" = "$out2" ] || fail "safe_tag fallback not deterministic across runs"
pass "safe_tag fallback is deterministic"

echo "OK"
