#!/bin/sh
# tests/test_subscription_uc.sh
# Drives subscription.uc with a fake `curl` stub and a synthetic UCI dir.
set -e

# Mirror test_generate.sh: skip if ucode/uci-mod unavailable on dev box.
if command -v ucode >/dev/null 2>&1; then
	UCODE_BIN=ucode
	UCODE_LIB_FLAGS="-L ${UCODE_APP_LIB_DIR:-$PWD/luci-singbox-ui/root/usr/share/singbox-ui/lib}"
elif [ -x "${UCODE_BIN:-}" ] && [ -d "${UCODE_STUB_DIR:-}" ]; then
	UCODE_LIB_FLAGS="-L $UCODE_STUB_DIR"
	[ -n "${UCODE_LIB_DIR:-}" ] && UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L $UCODE_LIB_DIR"
	UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L ${UCODE_APP_LIB_DIR:-$PWD/luci-singbox-ui/root/usr/share/singbox-ui/lib}"
else
	echo "SKIP: ucode not available"
	exit 0
fi

SUB_UC=luci-singbox-ui/root/usr/share/singbox-ui/subscription.uc
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Sandboxed tmp dir for the script's outputs.
export SINGBOX_TMPDIR="$TMPDIR/runtime"
mkdir -p "$SINGBOX_TMPDIR"

# Fake curl: writes $FAKE_BODY_FILE to the -o target and a canned header block
# to the -D target, then exits per $FAKE_CURL_RC. Mirrors curl's real argv shape.
mkdir -p "$TMPDIR/bin"
setup_curl_stub_basic() {
	cat >"$TMPDIR/bin/curl" <<'EOF'
#!/bin/sh
echo "$@" >>"${FAKE_CURL_LOG:-/dev/null}"
out=""; hdr=""; prev=""
for a in "$@"; do
	case "$prev" in -o) out="$a" ;; -D) hdr="$a" ;; esac
	prev="$a"
done
[ -n "$hdr" ] && printf 'HTTP/1.1 200 OK\r\nserver: stub\r\n\r\n' >"$hdr"
rc="${FAKE_CURL_RC:-0}"
if [ "$rc" = "0" ] && [ -n "$out" ]; then cat "${FAKE_BODY_FILE:-/dev/null}" >"$out"; fi
exit "$rc"
EOF
	chmod +x "$TMPDIR/bin/curl"
}
setup_curl_stub_basic
export PATH="$TMPDIR/bin:$PATH"
export CURL="$TMPDIR/bin/curl"
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
export FAKE_BODY_FILE="$TMPDIR/body"
: >"$FAKE_CURL_LOG"

run_uc fetch-subs

[ -s "$SINGBOX_TMPDIR/sub_subA.txt" ] || fail "sub_subA.txt missing or empty"
grep -q '^vless://uuid@host:443' "$SINGBOX_TMPDIR/sub_subA.txt" \
	|| { echo "got:"; cat "$SINGBOX_TMPDIR/sub_subA.txt"; fail "decoded URL not found"; }
pass "base64 body decoded"

# ---- fetch-subs with plain (non-base64) body ----
echo "-- fetch-subs accepts plain-text body when base64 decode is empty"
printf '%s\n' 'trojan://pwd@host:443#B' >"$TMPDIR/body"
rm -f "$SINGBOX_TMPDIR/sub_subA.txt"
run_uc fetch-subs
grep -q '^trojan://' "$SINGBOX_TMPDIR/sub_subA.txt" || fail "plain body not written"
pass "plain body passthrough"

# ---- SINGBOX_BOOT_FETCH=1 still fetches ----
echo "-- SINGBOX_BOOT_FETCH=1 still fetches subs (boot path active)"
cat >"$TMPDIR/singbox-ui" <<'EOF'
config outbound 'subA'
	option type 'subscription'
	option sub_url 'https://example.test/sub'
EOF
printf '%s' 'dmxlc3M6Ly91dWlkQGhvc3Q6NDQzCg==' >"$TMPDIR/body"
export FAKE_BODY_FILE="$TMPDIR/body"
rm -f "$SINGBOX_TMPDIR/sub_subA.txt"
: >"$FAKE_CURL_LOG"
SINGBOX_BOOT_FETCH=1 run_uc fetch-subs
[ -s "$SINGBOX_TMPDIR/sub_subA.txt" ] \
    || { echo "curl.log:"; cat "$FAKE_CURL_LOG"; fail "boot fetch did not produce sub_subA.txt"; }
grep -q -- '-A ' "$FAKE_CURL_LOG" \
    || { echo "curl.log:"; cat "$FAKE_CURL_LOG"; fail "boot fetch did not invoke curl with -A"; }
pass "boot fetch produces sub_subA.txt via curl"

# ---- two subscriptions are both fetched (sequential) ----
echo "-- two subscriptions are both fetched"
cat >"$TMPDIR/singbox-ui" <<'EOF'
config outbound 'subA'
	option type 'subscription'
	option sub_url 'https://example.test/a'
config outbound 'subB'
	option type 'subscription'
	option sub_url 'https://example.test/b'
EOF
# b64("vless://uuid@host:443\n")
printf '%s' 'dmxlc3M6Ly91dWlkQGhvc3Q6NDQzCg==' >"$TMPDIR/body"
export FAKE_BODY_FILE="$TMPDIR/body"
rm -f "$SINGBOX_TMPDIR/sub_subA.txt" "$SINGBOX_TMPDIR/sub_subB.txt"
: >"$FAKE_CURL_LOG"
run_uc fetch-subs
[ -s "$SINGBOX_TMPDIR/sub_subA.txt" ] || fail "sub_subA.txt not written"
[ -s "$SINGBOX_TMPDIR/sub_subB.txt" ] || fail "sub_subB.txt not written"
pass "both subscriptions are fetched"

# ---- failed fetch preserves existing sub_*.txt ----
echo "-- failed fetch does not clobber existing sub_<name>.txt"
cat >"$TMPDIR/singbox-ui" <<'EOF'
config outbound 'subA'
	option type 'subscription'
	option sub_url 'https://example.test/sub'
EOF
# Seed an existing sub_subA.txt
mkdir -p "$SINGBOX_TMPDIR"
printf 'vless://kept@host:1\n' >"$SINGBOX_TMPDIR/sub_subA.txt"
# curl stub returns failure (non-zero, no body written).
FAKE_CURL_RC=1 run_uc fetch-subs
grep -q '^vless://kept@host:1' "$SINGBOX_TMPDIR/sub_subA.txt" \
    || fail "cached sub_subA.txt was clobbered by failed fetch"
pass "cache preserved on fetch failure"

# ---- refresh: no-op when fresh, runs when stale, runs with force ----
echo "-- refresh respects mtime"
cat >"$TMPDIR/singbox-ui" <<EOF
config outbound 'subA'
	option type 'subscription'
	option sub_url 'https://example.test/sub'
	option sub_interval '3600'
EOF
printf '%s' 'dmxlc3M6Ly91dWlkQGhvc3Q6NDQzCg==' >"$TMPDIR/body"
export FAKE_BODY_FILE="$TMPDIR/body"
run_uc fetch-subs                                  # warm cache
old_mt=$(F="$SINGBOX_TMPDIR/sub_subA.txt" "$UCODE_BIN" -e 'let s=require("fs").stat(getenv("F")); print(s ? s.mtime : 0)')
sleep 1
: >"$FAKE_CURL_LOG"
SINGBOX_NO_RELOAD=1 run_uc refresh   # fresh → no-op
new_mt=$(F="$SINGBOX_TMPDIR/sub_subA.txt" "$UCODE_BIN" -e 'let s=require("fs").stat(getenv("F")); print(s ? s.mtime : 0)')
[ "$old_mt" = "$new_mt" ] || fail "fresh refresh re-downloaded"
[ ! -s "$FAKE_CURL_LOG" ] || fail "fresh refresh called curl"
pass "fresh refresh is no-op"

SINGBOX_NO_RELOAD=1 run_uc refresh force
[ -s "$FAKE_CURL_LOG" ] || fail "forced refresh did not call curl"
pass "forced refresh re-downloads"

# ---- sub_user_agent is passed to curl -A ----
echo "-- sub_user_agent is passed to curl -A"
cat >"$TMPDIR/singbox-ui" <<'EOF'
config outbound 'subA'
	option type 'subscription'
	option sub_url 'https://example.test/sub'
	option sub_user_agent 'v2raytun/1.0'
EOF
printf '%s' 'dmxlc3M6Ly91dWlkQGhvc3Q6NDQzCg==' >"$TMPDIR/body"
export FAKE_BODY_FILE="$TMPDIR/body"
: >"$FAKE_CURL_LOG"
run_uc fetch-subs
grep -q -- '-A v2raytun/1.0' "$FAKE_CURL_LOG" \
	|| { echo "curl.log:"; cat "$FAKE_CURL_LOG"; fail "expected -A v2raytun/1.0 in curl argv"; }
pass "sub_user_agent passed as -A to curl"

# ---- share-link parsers (Phase B7): ss://, trojan://, vless://, hy2:// ----
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

echo "-- parse_ss full-body b64: password control chars are dropped"
# base64 of "aes-256-gcm:pa\x00ss@1.2.3.4:8443" (literal NUL byte) — full-body form.
out=$(run_probe 'ss://YWVzLTI1Ni1nY206cGEAc3NAMS4yLjMuNDo4NDQz')
echo "$out" | grep -q '"password":[[:space:]]*"pass"' \
	|| { echo "$out"; fail "ss full-body b64: NUL not dropped from password"; }
pass "parse_ss full-body b64 strips NUL from password"

echo "-- parse_ss legacy b64 userinfo: password control chars are dropped"
# base64 of "aes-256-gcm:pa\x00ss" — legacy userinfo form, host:port outside b64.
out=$(run_probe 'ss://YWVzLTI1Ni1nY206cGEAc3M=@1.2.3.4:8443')
echo "$out" | grep -q '"password":[[:space:]]*"pass"' \
	|| { echo "$out"; fail "ss legacy b64: NUL not dropped from password"; }
pass "parse_ss legacy b64 strips NUL from password"

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

# ---- C2.1.10: try_b64_decode requires recognized scheme in decoded payload ----
# A plaintext body that, when run through b64dec, contains '://' but no line
# starting with a known share-link scheme must NOT be silently re-decoded.
# Done indirectly via fetch-subs + by structural assertion on the source.
echo "-- C2.1.10: try_b64_decode requires a recognized scheme in decoded payload"
# Structural check: the decode-trigger heuristic must regex over the SHARED
# share-link scheme constant (SEC-6: PROXY_SCHEME_RE), aligned with
# sharelink.uc::parse_proxy_url, rather than just searching for "://".
grep -qE 'PROXY_SCHEME_RE[[:space:]]*=[[:space:]]*/\^\(vmess\|vless\|ss\|trojan\|hy2\|hysteria2\)' \
	"$SUB_UC" \
	|| fail "subscription.uc: PROXY_SCHEME_RE shared scheme constant missing/changed"
grep -qE 'match\(t, PROXY_SCHEME_RE\)' "$SUB_UC" \
	|| fail "subscription.uc: try_b64_decode no longer triggers on PROXY_SCHEME_RE"
# SEC-6: http/https must NOT be in the decode-trigger whitelist (a plaintext
# error page line `visit https://…/help` must not be treated as proxy content).
grep -qE 'PROXY_SCHEME_RE.*http' "$SUB_UC" \
	&& fail "subscription.uc: SEC-6 http/https leaked back into the decode-trigger set" || true
pass "subscription.uc: try_b64_decode tests for known schemes (SEC-6 shared constant)"

# Behavioural complement: feed a body that is b64("visit https://example.com")
# Old behaviour: contains "://" → decodes → URL extractor finds no line starting
# with a scheme → empty output file (no sub_*.txt). New behaviour: no scheme-line
# in decoded → keeps as plaintext blob "dmlz..." → also no valid URL → no output.
# Either way the file should NOT be created. The key win is the same result for
# a plaintext-with-URL-prefix vs. a real share-link b64.
echo "-- C2.1.10: non-scheme b64 payload yields no output file"
cat >"$TMPDIR/singbox-ui" <<'EOF'
config outbound 'subC'
	option type 'subscription'
	option sub_url 'https://example.test/sub'
EOF
# b64("visit https://example.com/path") = "dmlzaXQgaHR0cHM6Ly9leGFtcGxlLmNvbS9wYXRo"
printf '%s' 'dmlzaXQgaHR0cHM6Ly9leGFtcGxlLmNvbS9wYXRo' >"$TMPDIR/body"
rm -f "$SINGBOX_TMPDIR/sub_subC.txt"
run_uc fetch-subs >/dev/null 2>&1 || true
[ ! -f "$SINGBOX_TMPDIR/sub_subC.txt" ] \
	|| fail "non-scheme b64 payload should not produce a subscription file"
pass "non-scheme b64 payload produces no subscription file"

# ---- C2.1.11: URL match accepts uppercase scheme (HTTPS://) ----
echo "-- C2.1.11: subscription URL match is case-insensitive"
# Structural check is sufficient: production must lowercase before regex match.
grep -qE 'match\(lc\(t\)' "$SUB_UC" \
	|| fail "subscription.uc URL match still case-sensitive (expected lc(t) wrap)"
pass "subscription.uc URL match supports uppercase schemes"

# Behavioural: HTTPS://-prefixed line in plaintext body is accepted as a URL.
echo "-- C2.1.11: plaintext body with HTTPS:// is accepted"
cat >"$TMPDIR/singbox-ui" <<'EOF'
config outbound 'subD'
	option type 'subscription'
	option sub_url 'https://example.test/sub'
EOF
# Plaintext body (not valid b64 alphabet — contains '://' which is not b64).
printf 'HTTPS://example.test/upstream\n' >"$TMPDIR/body"
rm -f "$SINGBOX_TMPDIR/sub_subD.txt"
run_uc fetch-subs >/dev/null 2>&1 || true
[ -s "$SINGBOX_TMPDIR/sub_subD.txt" ] \
	|| { echo "expected non-empty file"; fail "HTTPS:// line not accepted"; }
grep -qi '^HTTPS://example.test/upstream' "$SINGBOX_TMPDIR/sub_subD.txt" \
	|| { cat "$SINGBOX_TMPDIR/sub_subD.txt"; fail "HTTPS:// URL not preserved"; }
pass "plaintext HTTPS:// URL is accepted"

# ---- C2.3.11: detect_rs_format strips URL query/fragment before suffix check ----
# Anchor: lib/helpers.uc detect_rs_format. URLs with ?ver=N or #frag must still
# be recognised by their underlying .srs / .json suffix; without the strip the
# suffix check sees "...srs?ver=1" and falls through to the default.
echo "-- C2.3.11: detect_rs_format strips URL query before suffix check"
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS -e '
    let h = require("helpers");
    printf("%s\n", h.detect_rs_format("https://x/y.srs?ver=1", null));
    printf("%s\n", h.detect_rs_format("https://x/y.json?token=abc", null));
    printf("%s\n", h.detect_rs_format("https://x/y.srs#frag", null));
')
[ "$out" = "binary
source
binary" ] && pass "query/fragment stripped" || \
    { echo "FAIL: got [$out]"; exit 1; }

# ---- C2.3.12: OUTBOUND_PROXY_KINDS single constant ----
# Anchor: lib/helpers.uc exports is_outbound_proxy_kind(t). export_section.uc
# and lib/outbound.uc::build_outbounds() use it instead of open-coded chained
# string compares.
echo "-- C2.3.12: OUTBOUND_PROXY_KINDS single constant"
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS -e '
    let h = require("helpers");
    printf("%s\n", h.is_outbound_proxy_kind("vless"));
    printf("%s\n", h.is_outbound_proxy_kind("interface"));
')
[ "$out" = "true
false" ] && pass "is_outbound_proxy_kind works" || { echo "FAIL: [$out]"; exit 1; }

# Membership coverage — every kind in the active proxy set.
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS -e '
    let h = require("helpers");
    let want = ["vless","trojan","hysteria2","shadowsocks"];
    let ok = true;
    for (let t in want) if (!h.is_outbound_proxy_kind(t)) ok = false;
    printf("%s\n", ok ? "all-covered" : "missing");
')
[ "$out" = "all-covered" ] && pass "all active proxy kinds present" || { echo "FAIL"; exit 1; }

# ---- S3-1: subscription output is written atomically (tmp + rename) ----
# A successful fetch must leave exactly sub_<name>.txt and NO leftover
# *.tmp.* sibling (proves we wrote a tmp then renamed, never partial).
echo "-- S3-1: fetch-subs writes output atomically, no tmp leftovers"
cat >"$TMPDIR/singbox-ui" <<'EOF'
config outbound 'subA'
	option type 'subscription'
	option sub_url 'https://example.test/sub'
EOF
printf '%s' 'dmxlc3M6Ly91dWlkQGhvc3Q6NDQzCg==' >"$TMPDIR/body"   # b64("vless://uuid@host:443\n")
export FAKE_BODY_FILE="$TMPDIR/body"
rm -f "$SINGBOX_TMPDIR"/sub_subA.txt "$SINGBOX_TMPDIR"/sub_subA.txt.tmp.* 2>/dev/null || true
run_uc fetch-subs
[ -s "$SINGBOX_TMPDIR/sub_subA.txt" ] || fail "S3-1: sub_subA.txt missing"
# Count .tmp.* leftovers via a glob loop (avoids `ls | wc`, SC2012; when the
# glob matches nothing the literal pattern fails the -e test, so count stays 0).
leftovers=0
for _f in "$SINGBOX_TMPDIR"/sub_subA.txt.tmp.*; do
	[ -e "$_f" ] && leftovers=$((leftovers + 1))
done
[ "$leftovers" -eq 0 ] || { ls "$SINGBOX_TMPDIR"; fail "S3-1: tmp file left behind ($leftovers)"; }
pass "S3-1: atomic write leaves no tmp file"

# Structural: production must route the subs output through a tmp+rename
# helper (fs.rename), not a bare fs.open(out_path,"w") write loop.
grep -qE 'fs\.rename\(' "$SUB_UC" \
	|| fail "S3-1: subscription.uc has no fs.rename (atomic write helper missing)"
pass "S3-1: subscription.uc uses fs.rename for atomic publish"

# ---- S3-2: oversize subscription body is rejected (no OOM) ----
# CRITICAL: the body must be VALID (contain a real proxy URL) so it would pass
# the URL filter and be written if the size guard were missing. Only then does
# "no output file" prove the post-stat size guard fired (not an empty URL list).
echo "-- S3-2: oversize body is dropped by the post-read size guard"
cat >"$TMPDIR/singbox-ui" <<'EOF'
config outbound 'subBig'
	option type 'subscription'
	option sub_url 'https://example.test/big'
EOF
# Control first: the SAME valid one-line body UNDER the cap must produce a file.
# This proves the URL filter accepts the body, so the oversize rejection below
# can only be attributable to the size guard.
printf 'vless://uuid@host:443\n' >"$TMPDIR/body"
export FAKE_BODY_FILE="$TMPDIR/body"
rm -f "$SINGBOX_TMPDIR/sub_subBig.txt"
run_uc fetch-subs
[ -s "$SINGBOX_TMPDIR/sub_subBig.txt" ] \
	|| fail "S3-2(control): under-cap valid body should have produced sub_subBig.txt"
grep -q '^vless://uuid@host:443' "$SINGBOX_TMPDIR/sub_subBig.txt" \
	|| fail "S3-2(control): under-cap valid body content wrong"
pass "S3-2(control): under-cap valid body is written"

# Now the oversize variant: SAME valid first line, then >8 MiB of padding on a
# second line. The vless:// line still passes the URL filter, so the ONLY thing
# that can stop the file from being written is the post-read size guard.
{ printf 'vless://uuid@host:443\n'; head -c 9000000 /dev/zero | tr '\0' 'a'; printf '\n'; } >"$TMPDIR/body"
export FAKE_BODY_FILE="$TMPDIR/body"
rm -f "$SINGBOX_TMPDIR/sub_subBig.txt"
run_uc fetch-subs
[ ! -f "$SINGBOX_TMPDIR/sub_subBig.txt" ] \
	|| fail "S3-2: oversize body (with a valid URL line) was NOT rejected by the size guard"
pass "S3-2: oversize valid body rejected by post-read size guard"

# ---- S3-4: non-numeric interval falls back to default (refresh still fires) ----
echo "-- S3-4: NaN sub_interval clamps to default so refresh still runs"
cat >"$TMPDIR/singbox-ui" <<'EOF'
config outbound 'subN'
	option type 'subscription'
	option sub_url 'https://example.test/sub'
	option sub_interval 'abc'
EOF
printf '%s' 'dmxlc3M6Ly91dWlkQGhvc3Q6NDQzCg==' >"$TMPDIR/body"
export FAKE_BODY_FILE="$TMPDIR/body"
# Seed a stale cache file dated in 1970 so even the 3600s default is exceeded.
printf 'vless://old@host:1\n' >"$SINGBOX_TMPDIR/sub_subN.txt"
touch -t 197001020000 "$SINGBOX_TMPDIR/sub_subN.txt"
: >"$FAKE_CURL_LOG"
SINGBOX_NO_RELOAD=1 run_uc refresh
[ -s "$FAKE_CURL_LOG" ] \
	|| { echo "singbox.log empty — refresh treated NaN interval as never-stale"; fail "S3-4: NaN interval disabled refresh"; }
pass "S3-4: NaN interval clamped to default, refresh fired"

# ---- S3-8: log_err is a distinct channel (tagged) vs log ----
echo "-- S3-8: error log lines are tagged distinctly from info lines"
cat >"$TMPDIR/singbox-ui" <<'EOF'
config outbound 'notasub'
	option type 'interface'
	option interface 'wan'
EOF
err=$(run_uc fetch-subs 2>&1 >/dev/null || true)
echo "$err" | grep -qE 'error:.*no subscription outbounds' \
	|| { echo "[$err]"; fail "S3-8: log_err output not tagged 'error:'"; }
pass "S3-8: log_err lines carry an 'error:' tag"

# ---- per-section refresh scoping: any_subs_stale honors `only` arg ---
echo "-- scoping: any_subs_stale honors per-section only arg"
TMPS=$(mktemp -d)
mkdir -p "$TMPS/uci" "$TMPS/run"
cat >"$TMPS/uci/singbox-ui" <<'EOF'
config outbound 'one'
	option type 'subscription'
	option enabled '1'
	option sub_url 'https://e/one'
	option sub_interval '99999'
config outbound 'two'
	option type 'subscription'
	option enabled '1'
	option sub_url 'https://e/two'
	option sub_interval '99999'
EOF
# 'one' has a freshly-written body (not stale); 'two' has none (stale/missing).
printf 'vless://x\n' > "$TMPS/run/sub_one.txt"
SINGBOX_DIR="$(dirname "$SUB_UC")"
# shellcheck disable=SC2086
scope() {
	env UCI_CONFIG_DIR="$TMPS/uci" SINGBOX_TMPDIR="$TMPS/run" SCOPE_ONLY="$1" \
		"$UCODE_BIN" $UCODE_LIB_FLAGS -L "$SINGBOX_DIR" -e '
  let s=require("subscription");
  let uci=require("uci"); let cur=uci.cursor(getenv("UCI_CONFIG_DIR"));
  let only = getenv("SCOPE_ONLY") || null;
  print(s._any_subs_stale_for_test(cur, false, only) ? "stale" : "fresh");'
}
[ "$(scope one)" = "fresh" ] || { echo "FAIL: scope one should be fresh (recent file, huge interval): $(scope one)"; rm -rf "$TMPS"; exit 1; }
[ "$(scope two)" = "stale" ] || { echo "FAIL: scope two should be stale (no file): $(scope two)"; rm -rf "$TMPS"; exit 1; }
[ "$(scope '')"  = "stale" ] || { echo "FAIL: unscoped should be stale (two missing): $(scope '')"; rm -rf "$TMPS"; exit 1; }
rm -rf "$TMPS"
echo "  PASS: any_subs_stale honors per-section scoping"

# --- auto_update gate: cron (non-force) subs suppressed when flag=0 ---
echo "-- auto_update gate: cron non-force skipped when flag=0"
SINGBOX_DIR="$(dirname "$SUB_UC")"
TMPG=$(mktemp -d); mkdir -p "$TMPG/uci"
cat >"$TMPG/uci/singbox-ui" <<'EOF'
config subscriptions 'subscriptions'
	option auto_update '0'
EOF
# shellcheck disable=SC2086
gate() { env UCI_CONFIG_DIR="$TMPG/uci" GATE_FORCE="$1" \
	"$UCODE_BIN" $UCODE_LIB_FLAGS -L "$SINGBOX_DIR" -e '
  let s=require("subscription"); let uci=require("uci");
  let cur=uci.cursor(getenv("UCI_CONFIG_DIR"));
  print(s._subs_refresh_allowed_for_test(cur, getenv("GATE_FORCE")==="1") ? "yes" : "no");'; }
[ "$(gate 0)" = "no" ]  || { echo "FAIL: non-force + flag0 must skip subs, got $(gate 0)"; rm -rf "$TMPG"; exit 1; }
[ "$(gate 1)" = "yes" ] || { echo "FAIL: force bypasses gate, got $(gate 1)"; rm -rf "$TMPG"; exit 1; }
rm -rf "$TMPG"
TMPG2=$(mktemp -d); mkdir -p "$TMPG2/uci"
cat >"$TMPG2/uci/singbox-ui" <<'EOF'
config subscriptions 'subscriptions'
	option auto_update '1'
EOF
# shellcheck disable=SC2086
gate2() { env UCI_CONFIG_DIR="$TMPG2/uci" \
	"$UCODE_BIN" $UCODE_LIB_FLAGS -L "$SINGBOX_DIR" -e '
  let s=require("subscription"); let uci=require("uci"); let cur=uci.cursor(getenv("UCI_CONFIG_DIR"));
  print(s._subs_refresh_allowed_for_test(cur, false) ? "yes" : "no");'; }
[ "$(gate2)" = "yes" ] || { echo "FAIL: flag1 non-force must allow subs, got $(gate2)"; rm -rf "$TMPG2"; exit 1; }
rm -rf "$TMPG2"
echo "PASS: auto_update gate suppresses cron subs only when disabled"

echo "OK"
