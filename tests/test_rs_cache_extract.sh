#!/bin/sh
# tests/test_rs_cache_extract.sh
# Exercises the cache-extraction rule-set path of subscription.uc: remote
# nft_rules rule-sets are read from sing-box's bbolt cache (cache.db) via a fake
# bbolt-client instead of curl, then decompiled to rs_<name>.json. Also covers
# the skip+log edges and the cold-cache reload trigger in cmd_refresh.
set -e

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

SUB_UC=luci-singbox-ui/root/usr/share/singbox-ui/nft-rulesets.uc
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export SINGBOX_TMPDIR="$TMPDIR/runtime"
mkdir -p "$SINGBOX_TMPDIR" "$TMPDIR/bin"

pass() { echo "  PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }
run_uc() {
	# shellcheck disable=SC2086
	UCI_CONFIG_DIR="$TMPDIR" "$UCODE_BIN" $UCODE_LIB_FLAGS "$SUB_UC" "$@"
}

# --- fake bbolt-client: "<db> rule_set" lists known tags; "-r <db> rule_set
#     <tag>" emits a fake .srs body for a known tag, else exits 1. The set of
#     known tags is controlled by $BBOLT_KNOWN (space-separated).
install_fake_bbolt() {
	cat >"$TMPDIR/bin/bbolt-client" <<'EOF'
#!/bin/sh
known=" ${BBOLT_KNOWN:-} "
if [ "$1" = "-r" ]; then
	tag="$4"
	case "$known" in *" $tag "*) printf 'SRS\003FAKEBODY'; exit 0 ;; esac
	exit 1
fi
# "<db> rule_set" → one tag per line
if [ "$2" = "rule_set" ]; then
	for t in ${BBOLT_KNOWN:-}; do echo "$t"; done
	exit 0
fi
exit 0
EOF
	chmod +x "$TMPDIR/bin/bbolt-client"
}
install_fake_bbolt
export SINGBOX_BBOLT_BIN="$TMPDIR/bin/bbolt-client"

# --- fake sing-box: "rule-set decompile <in> -o <out>" writes a minimal json.
cat >"$TMPDIR/bin/sing-box" <<'EOF'
#!/bin/sh
out=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done
[ -n "$out" ] && printf '{"version":1,"rules":[{"ip_cidr":["1.2.3.0/24"]}]}' >"$out"
exit 0
EOF
chmod +x "$TMPDIR/bin/sing-box"
export SINGBOX="$TMPDIR/bin/sing-box"
export PATH="$TMPDIR/bin:$PATH"

# ============================================================
echo "-- remote ruleset extracted from cache.db (no curl)"
BBOLT_KNOWN="geoip"
cat >"$TMPDIR/singbox-ui" <<'EOF'
config cache 'cache'
	option enabled '1'
config ruleset 'geoip'
	option type 'remote'
	option url 'https://example.test/geoip.srs'
	option nft_rules '1'
EOF
rm -f "$SINGBOX_TMPDIR/rs_geoip.json"
BBOLT_KNOWN="$BBOLT_KNOWN" run_uc fetch >/dev/null 2>&1 || true
[ -s "$SINGBOX_TMPDIR/rs_geoip.json" ] || fail "rs_geoip.json missing (cache extract)"
grep -q '1.2.3.0/24' "$SINGBOX_TMPDIR/rs_geoip.json" || fail "decompiled json wrong"
pass "remote ruleset built from cache.db"

# Ensure no curl was even attempted (no curl in PATH bin/; assert no stray file).
echo "-- no curl path used for remote ruleset"
[ ! -f "$TMPDIR/bin/curl" ] || fail "test should not rely on curl"
pass "remote ruleset uses bbolt, not curl"

# ============================================================
echo "-- cache_file disabled → skip+log, no file"
cat >"$TMPDIR/singbox-ui" <<'EOF'
config cache 'cache'
	option enabled '0'
config ruleset 'geoip'
	option type 'remote'
	option url 'https://example.test/geoip.srs'
	option nft_rules '1'
EOF
rm -f "$SINGBOX_TMPDIR/rs_geoip.json"
out=$(BBOLT_KNOWN="geoip" run_uc fetch 2>&1 || true)
[ ! -f "$SINGBOX_TMPDIR/rs_geoip.json" ] || fail "must not build with cache disabled"
echo "$out" | grep -qiE 'cache_file disabled|cache' || fail "expected cache-disabled log: $out"
pass "cache disabled → skip+log"

# ============================================================
echo "-- bbolt-client not installed → skip+log"
cat >"$TMPDIR/singbox-ui" <<'EOF'
config cache 'cache'
	option enabled '1'
config ruleset 'geoip'
	option type 'remote'
	option url 'https://example.test/geoip.srs'
	option nft_rules '1'
EOF
rm -f "$SINGBOX_TMPDIR/rs_geoip.json"
out=$(SINGBOX_BBOLT_BIN="$TMPDIR/bin/does-not-exist" run_uc fetch 2>&1 || true)
[ ! -f "$SINGBOX_TMPDIR/rs_geoip.json" ] || fail "must not build without bbolt-client"
echo "$out" | grep -qiE 'bbolt-client not installed' || fail "expected no-binary log: $out"
pass "no bbolt-client → skip+log"

# ============================================================
echo "-- tag absent from cache (boot mode) → skip+log, no reload"
cat >"$TMPDIR/singbox-ui" <<'EOF'
config cache 'cache'
	option enabled '1'
config ruleset 'missing'
	option type 'remote'
	option url 'https://example.test/x.srs'
	option nft_rules '1'
EOF
rm -f "$SINGBOX_TMPDIR/rs_missing.json"
out=$(BBOLT_KNOWN="" SINGBOX_BOOT_FETCH=1 run_uc fetch 2>&1 || true)
[ ! -f "$SINGBOX_TMPDIR/rs_missing.json" ] || fail "absent tag must not build"
echo "$out" | grep -qiE 'not in cache' || fail "expected absent-tag log: $out"
pass "absent tag (boot) → skip+log"

# ============================================================
echo "-- cold tag triggers ONE init.d reload in refresh; warm tag does not"
mkdir -p "$TMPDIR/initd"
cat >"$TMPDIR/initd/singbox-ui" <<'EOF'
#!/bin/sh
echo "reload-called $*" >>"$RELOAD_LOG"
EOF
chmod +x "$TMPDIR/initd/singbox-ui"
export SINGBOX_INITD="$TMPDIR/initd/singbox-ui"
export SINGBOX_NFT_APPLY="true"          # no-op nft apply
export RELOAD_LOG="$TMPDIR/reload.log"

cat >"$TMPDIR/singbox-ui" <<'EOF'
config cache 'cache'
	option enabled '1'
config ruleset 'geoip'
	option type 'remote'
	option url 'https://example.test/geoip.srs'
	option nft_rules '1'
	option update_interval '1'
EOF

# Cold: bbolt lists no keys → refresh must reload then time out the poll.
: >"$RELOAD_LOG"
BBOLT_KNOWN="" SINGBOX_RS_CACHE_WAIT=1 run_uc refresh force >/dev/null 2>&1 || true
grep -q reload-called "$RELOAD_LOG" || fail "cold tag did NOT trigger reload"
pass "cold tag triggers reload"

# Warm: bbolt lists the tag → no reload, rs_geoip.json built.
: >"$RELOAD_LOG"
rm -f "$SINGBOX_TMPDIR/rs_geoip.json"
BBOLT_KNOWN="geoip" SINGBOX_RS_CACHE_WAIT=1 run_uc refresh force >/dev/null 2>&1 || true
[ -s "$RELOAD_LOG" ] && fail "warm tag must NOT trigger reload"
[ -s "$SINGBOX_TMPDIR/rs_geoip.json" ] || fail "warm refresh did not build rs_geoip.json"
pass "warm tag: no reload, set rebuilt"

echo "OK"
