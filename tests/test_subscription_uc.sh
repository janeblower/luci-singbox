#!/bin/sh
# tests/test_subscription_uc.sh
# Drives subscription.uc with a fake curl on PATH and a synthetic UCI dir.
set -e

# Mirror test_generate.sh: skip if ucode/uci-mod unavailable on dev box.
if command -v ucode >/dev/null 2>&1; then
	UCODE_BIN=ucode
	UCODE_LIB_FLAGS=""
elif [ -x "${UCODE_BIN:-}" ] && [ -d "${UCODE_STUB_DIR:-}" ]; then
	UCODE_LIB_FLAGS="-L $UCODE_STUB_DIR"
	[ -n "${UCODE_LIB_DIR:-}" ] && UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L $UCODE_LIB_DIR"
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
	option proxy_type 'subscription'
config outbound 'b'
	option proxy_type 'interface'
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
	option proxy_type 'subscription'
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

# ---- refresh: no-op when fresh, runs when stale, runs with force ----
echo "-- refresh respects mtime"
cat >"$TMPDIR/singbox-ui" <<EOF
config outbound 'subA'
	option proxy_type 'subscription'
	option sub_url 'https://example.test/sub'
	option sub_interval '3600'
EOF
printf '%s' 'dmxlc3M6Ly91dWlkQGhvc3Q6NDQzCg==' >"$TMPDIR/body"
run_uc fetch-subs                                  # warm cache
old_mt=$(stat -c %Y "$SINGBOX_TMPDIR/sub_subA.txt")
sleep 1
: >"$FAKE_CURL_LOG"
SINGBOX_NO_RELOAD=1 run_uc refresh subscriptions   # fresh → no-op
new_mt=$(stat -c %Y "$SINGBOX_TMPDIR/sub_subA.txt")
[ "$old_mt" = "$new_mt" ] || fail "fresh refresh re-downloaded"
[ ! -s "$FAKE_CURL_LOG" ] || fail "fresh refresh called curl"
pass "fresh refresh is no-op"

SINGBOX_NO_RELOAD=1 run_uc refresh subscriptions force
[ -s "$FAKE_CURL_LOG" ] || fail "forced refresh did not call curl"
pass "forced refresh re-downloads"

echo "OK"
