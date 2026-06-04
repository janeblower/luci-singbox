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

echo "OK"
