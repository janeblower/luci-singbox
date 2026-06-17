#!/bin/sh
set -eu
. "$(dirname "$0")/../lib/sb_helpers.sh"
fail() { echo "FAIL: $1"; exit 1; }
[ -d "$SB_LIB" ]   || fail "SB_LIB missing: $SB_LIB"
[ -f "$SB_RPCD" ]  || fail "SB_RPCD missing: $SB_RPCD"
[ -f "$SB_ACL" ]   || fail "SB_ACL missing: $SB_ACL"
[ -d "$SB_VIEW" ]  || fail "SB_VIEW missing: $SB_VIEW"
out="$(SB_BACKEND_ROOT=/tmp/x sh -c '. tests/lib/sb_helpers.sh; printf %s "$SB_LIB"')"
[ "$out" = "/tmp/x/usr/share/singbox-ui/lib" ] || fail "env override broke: $out"
echo PASS
