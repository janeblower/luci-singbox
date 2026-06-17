#!/bin/sh
# tests/test_cache_uc.sh — exercises lib/cache.uc storage modes via a
# tiny ucode wrapper that hand-feeds singbox-ui sections. Mirrors the
# harness pattern in test_dns_uc.sh.
set -e
. "$(dirname "$0")/../lib/sb_helpers.sh"

if command -v ucode >/dev/null 2>&1; then
	UCODE_BIN=ucode
	UCODE_LIB_FLAGS="-L ${UCODE_APP_LIB_DIR:-$PWD/${SB_LIB}}"
elif [ -x "${UCODE_BIN:-}" ] && [ -d "${UCODE_STUB_DIR:-}" ]; then
	UCODE_LIB_FLAGS="-L ${UCODE_STUB_DIR} -L ${UCODE_APP_LIB_DIR:-$PWD/${SB_LIB}}"
else
	echo "ucode not found — skipping" >&2
	exit 0
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

run_case() {
	label="$1"; expect_path="$2"; expect_fakeip="$3"; extras="$4"
	cat >"$TMPDIR/run.uc" <<UCODE
let uci = require("uci");
let cache = require("cache");
let cur = uci.cursor("$TMPDIR/cfg");
let out = cache.build_cache(cur);
printf("%J\n", out);
UCODE
	mkdir -p "$TMPDIR/cfg"
	{
		echo "config cache 'cache'"
		echo "    option enabled '1'"
		printf '%s\n' "$extras"
	} >"$TMPDIR/cfg/singbox-ui"

	# shellcheck disable=SC2086
	actual=$(UCI_CONFIG_DIR="$TMPDIR/cfg" "$UCODE_BIN" $UCODE_LIB_FLAGS "$TMPDIR/run.uc")
	echo "$actual" | grep -q "\"path\": \"$expect_path\"" \
		|| { echo "FAIL [$label]: expected path=$expect_path"; echo "$actual"; exit 1; }
	if [ "$expect_fakeip" = "yes" ]; then
		echo "$actual" | grep -q '"store_fakeip": true' \
			|| { echo "FAIL [$label]: expected store_fakeip:true"; echo "$actual"; exit 1; }
	else
		if echo "$actual" | grep -q '"store_fakeip": true'; then
			echo "FAIL [$label]: store_fakeip should be absent"; echo "$actual"; exit 1
		fi
	fi
	echo "ok [$label]"
}

# Storage modes
run_case ram_default   "/tmp/singbox-ui-cache.db"  no  "    option storage 'ram'"
run_case flash_default "/etc/sing-box/cache.db"    no  "    option storage 'flash'"
run_case custom_path   "/srv/cache.db"             no  "    option storage 'custom'
    option path '/srv/cache.db'"
run_case legacy_blank  "/tmp/singbox-ui-cache.db"  no  ""

# fakeip toggle requires an enabled dns_server of type=fakeip; add one.
EXTRA_FAKEIP="    option storage 'ram'
    option store_fakeip '1'

config dns_server 'fakeip'
    option enabled '1'
    option type 'fakeip'"
run_case with_fakeip   "/tmp/singbox-ui-cache.db"  yes "$EXTRA_FAKEIP"

# store_fakeip without a fakeip server must NOT emit (current contract).
NO_FAKEIP_SRV="    option storage 'ram'
    option store_fakeip '1'"
run_case fakeip_no_srv "/tmp/singbox-ui-cache.db"  no  "$NO_FAKEIP_SRV"

# ---------------------------------------------------------------------------
# C2.1.13: clash.uc external_controller bracketing
# ---------------------------------------------------------------------------
# IPv6 listen addresses must be wrapped in [brackets] so sing-box parses
# `external_controller` as host+port rather than mis-reading ':::9090' as
# port-of-empty-host. IPv4 must remain unbracketed for backwards compatibility.
run_clash_case() {
	label="$1"; listen="$2"; port="$3"; expect="$4"
	mkdir -p "$TMPDIR/cfg"
	cat >"$TMPDIR/cfg/singbox-ui" <<UCI
config clash_api 'clash_api'
    option enabled '1'
    option listen '$listen'
    option port '$port'
UCI
	cat >"$TMPDIR/run.uc" <<'UCODE'
let uci = require("uci");
let clash = require("clash");
let cur = uci.cursor(getenv("UCI_CONFIG_DIR"));
let out = clash.build_clash_api(cur);
print(out.external_controller);
UCODE
	# shellcheck disable=SC2086
	actual=$(UCI_CONFIG_DIR="$TMPDIR/cfg" "$UCODE_BIN" $UCODE_LIB_FLAGS "$TMPDIR/run.uc")
	[ "$actual" = "$expect" ] \
		|| { echo "FAIL [$label]: expected '$expect', got '$actual'"; exit 1; }
	echo "ok [$label]"
}

run_clash_case clash_ipv4_unbracketed "127.0.0.1" "9090" "127.0.0.1:9090"
run_clash_case clash_ipv6_bracketed   "::1"       "9090" "[::1]:9090"
run_clash_case clash_ipv6_any_bracketed "::"      "9090" "[::]:9090"

# ---- cache_db_path: on-disk path when cache enabled, null when disabled ----
echo "-- cache_db_path: enabled ram → /tmp path, disabled → null"
cat >"$TMPDIR/run2.uc" <<'UCODE'
let uci = require("uci"); let cache = require("cache");
let cur = uci.cursor(getenv("UCI_CONFIG_DIR"));
print(cache.cache_db_path(cur) ?? "null");
UCODE
mkdir -p "$TMPDIR/cfg2"
printf "config cache 'cache'\n\toption enabled '1'\n" >"$TMPDIR/cfg2/singbox-ui"
# shellcheck disable=SC2086
out=$(UCI_CONFIG_DIR="$TMPDIR/cfg2" "$UCODE_BIN" $UCODE_LIB_FLAGS "$TMPDIR/run2.uc")
[ "$out" = "/tmp/singbox-ui-cache.db" ] || { echo "FAIL cache_db_path enabled: got '$out'"; exit 1; }
printf "config cache 'cache'\n\toption enabled '0'\n" >"$TMPDIR/cfg2/singbox-ui"
# shellcheck disable=SC2086
out=$(UCI_CONFIG_DIR="$TMPDIR/cfg2" "$UCODE_BIN" $UCODE_LIB_FLAGS "$TMPDIR/run2.uc")
[ "$out" = "null" ] || { echo "FAIL cache_db_path disabled: got '$out'"; exit 1; }
# flash storage → /etc path
printf "config cache 'cache'\n\toption enabled '1'\n\toption storage 'flash'\n" >"$TMPDIR/cfg2/singbox-ui"
# shellcheck disable=SC2086
out=$(UCI_CONFIG_DIR="$TMPDIR/cfg2" "$UCODE_BIN" $UCODE_LIB_FLAGS "$TMPDIR/run2.uc")
[ "$out" = "/etc/sing-box/cache.db" ] || { echo "FAIL cache_db_path flash: got '$out'"; exit 1; }
echo "ok [cache_db_path]"

echo "OK"
