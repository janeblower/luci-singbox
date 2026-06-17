#!/bin/sh
# tests/test_refresh_name.sh
# call_refresh forwards a valid `name` as the 3rd CLI arg (`refresh force <name>`) to subscription.uc and
# rejects an invalid name (falls back to a global refresh, no name forwarded).
set -e
. "$(dirname "$0")/lib/sb_helpers.sh"
cd "$(dirname "$0")/.."
: "${UCODE_BIN:=$(command -v ucode)}"
[ -z "$UCODE_BIN" ] && { echo "SKIP: no ucode on host"; exit 0; }
LIB="$PWD/${SB_LIB}"
HANDLER="$PWD/${SB_RPCD}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Stub subscription.uc: a .uc script that records its ARGV to $ARGV_OUT and exits 0.
cat >"$TMP/sub_stub.uc" <<'EOF'
let fs=require("fs");
let f=fs.open(getenv("ARGV_OUT"),"w");
if (f) { f.write(join("\n", ARGV)); f.close(); }
EOF

callr() { # $1 = JSON args
  printf '%s' "$1" | env SUBSCRIPTION_UC="$TMP/sub_stub.uc" ARGV_OUT="$TMP/argv" \
    "$UCODE_BIN" -L "$LIB" "$HANDLER" call refresh >/dev/null 2>&1
  cat "$TMP/argv" 2>/dev/null
}

# valid name -> forwarded as a CLI arg
got=$(callr '{"what":"subscriptions","name":"mysub"}')
echo "$got" | grep -qx 'mysub' || { echo "FAIL: valid name not forwarded; argv=[$got]"; exit 1; }
echo "$got" | grep -qx 'force' || { echo "FAIL: force not forwarded; argv=[$got]"; exit 1; }

# invalid name (shell metachar) -> NOT forwarded (no 'a;b' token)
got=$(callr '{"what":"subscriptions","name":"a;b rm"}')
echo "$got" | grep -q ';' && { echo "FAIL: invalid name leaked into argv=[$got]"; exit 1; }

echo "PASS: refresh forwards valid name, rejects invalid"
