#!/bin/sh
# tests/test_audit_1_6.sh
# Regression for audit 1.6 (INFO — descriptor input validation / UX hardening):
#   - shadowsocks ss_user: warn()+skip entries with an unknown method or empty
#     password (the discarded middle token must still name a real cipher).
#   - vless inbound_user: warn()+skip entries whose uuid token is structurally
#     malformed (whitespace / non-UUID-class chars) instead of letting the bad
#     row flow into JSON and get rejected loudly by sing-box at load.
# Drives inbound.build_one() via the same `ucode -L lib` path test_inbounds_uc.sh
# uses. Asserts both the surviving JSON AND that bad entries emit a warn on
# stderr (warn+skip, not abort).
set -e
. "$(dirname "$0")/lib/sb_helpers.sh"

if command -v ucode >/dev/null 2>&1; then
	UCODE_BIN=ucode
	UCODE_LIB_FLAGS="-L ${UCODE_APP_LIB_DIR:-$PWD/${SB_LIB}}"
elif [ -x "${UCODE_BIN:-}" ] && [ -d "${UCODE_STUB_DIR:-}" ]; then
	UCODE_LIB_FLAGS="-L $UCODE_STUB_DIR -L ${UCODE_APP_LIB_DIR:-$PWD/${SB_LIB}}"
	[ -n "${UCODE_LIB_DIR:-}" ] && UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L $UCODE_LIB_DIR"
else
	echo "SKIP: ucode not available (set UCODE_BIN + UCODE_STUB_DIR [+ UCODE_LIB_DIR] to run locally)"
	exit 0
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# run_build "<ucode literal for s>" -> stdout=JSON in $TMPDIR/out, stderr=$TMPDIR/err
run_build() {
	# shellcheck disable=SC2086
	"$UCODE_BIN" $UCODE_LIB_FLAGS -e "
let inb = require('inbound');
let s = $1;
printf('%J', inb.build_one(s));
" >"$TMPDIR/out" 2>"$TMPDIR/err"
}
has()    { grep -q "$2" "$TMPDIR/out" || { echo "FAIL: $1 — '$2' not in JSON"; cat "$TMPDIR/out"; exit 1; }; echo "  PASS: $1"; }
hasnot() { grep -q "$2" "$TMPDIR/out" && { echo "FAIL: $1 — '$2' should be absent"; cat "$TMPDIR/out"; exit 1; }; echo "  PASS: $1"; }
warned() { grep -q "$2" "$TMPDIR/err" || { echo "FAIL: $1 — warn '$2' not on stderr"; cat "$TMPDIR/err"; exit 1; }; echo "  PASS: $1"; }

echo "-- shadowsocks ss_user: unknown method warn+skip, valid kept"
run_build "{
  '.name':'ss', 'protocol':'shadowsocks', 'listen':'::', 'listen_port':'8388',
  'shadowsocks_method':'aes-128-gcm',
  'ss_user':['bad:made-up-cipher:pw','good:aes-256-gcm:gp']
}"
has    "ss good user kept"        '\"name\": \"good\"'
has    "ss good password kept"    '\"password\": \"gp\"'
hasnot "ss unknown-method dropped" '\"name\": \"bad\"'
warned "ss unknown-method warns"   "unknown method 'made-up-cipher'"

echo "-- shadowsocks ss_user: empty password warn+skip"
run_build "{
  '.name':'ss', 'protocol':'shadowsocks', 'listen':'::', 'listen_port':'8388',
  'shadowsocks_method':'aes-128-gcm',
  'ss_user':['empty:aes-128-gcm:','good:aes-128-gcm:gp']
}"
has    "ss good user kept (empty case)" '\"name\": \"good\"'
hasnot "ss empty-pw dropped"            '\"name\": \"empty\"'
warned "ss empty-pw warns"              "empty password"

echo "-- vless inbound_user: malformed uuid warn+skip, valid kept"
run_build "{
  '.name':'vl', 'protocol':'vless', 'listen':'::', 'listen_port':'443',
  'inbound_user':['alice:11111111-1111-1111-1111-111111111111','bad:has space:flow','garbage:bad@@@uuid:x']
}"
has    "vless valid uuid kept"        '\"uuid\": \"11111111-1111-1111-1111-111111111111\"'
has    "vless valid name kept"        '\"name\": \"alice\"'
hasnot "vless space-uuid dropped"     '\"name\": \"bad\"'
hasnot "vless garbage-uuid dropped"   '\"name\": \"garbage\"'
warned "vless space-uuid warns"       "malformed uuid 'has space'"
warned "vless garbage-uuid warns"     "malformed uuid 'bad@@@uuid'"

echo "-- vless inbound_user: permissive identifiers (e.g. placeholder tokens) still pass"
# A non-canonical but structurally-clean token (hex+letters+hyphens) must NOT be
# dropped — the check is intentionally loose, only clearly-broken tokens go.
run_build "{
  '.name':'vl', 'protocol':'vless', 'listen':'::', 'listen_port':'443',
  'inbound_user':['carol:uuid-ccc']
}"
has    "vless loose token kept"       '\"uuid\": \"uuid-ccc\"'
warned_absent() { grep -q "malformed uuid" "$TMPDIR/err" && { echo "FAIL: loose token should not warn"; cat "$TMPDIR/err"; exit 1; }; echo "  PASS: loose token does not warn"; }
warned_absent

echo "OK"
