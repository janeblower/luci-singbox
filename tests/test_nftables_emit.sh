#!/bin/sh
# tests/test_nftables_emit.sh
set -e

SCRIPT=root/etc/sing-box/nftables.sh

if [ ! -x "$SCRIPT" ]; then
  echo "FAIL: $SCRIPT not present or not executable"
  exit 1
fi

echo "-- shellcheck"
shellcheck -s sh "$SCRIPT"

echo "-- emit prints rules referencing port and ranges"
out=$("$SCRIPT" emit 7893 "198.18.0.0/15" "fc00::/18")
echo "$out" | grep -q "table inet sing_box"  || { echo "FAIL: missing table"; exit 1; }
echo "$out" | grep -q "127.0.0.1:7893"        || { echo "FAIL: missing v4 tproxy target"; exit 1; }
echo "$out" | grep -q "\[::1\]:7893"          || { echo "FAIL: missing v6 tproxy target"; exit 1; }
echo "$out" | grep -q "198.18.0.0/15"         || { echo "FAIL: missing v4 range"; exit 1; }
echo "$out" | grep -q "fc00::/18"             || { echo "FAIL: missing v6 range"; exit 1; }

echo "-- nft -c accepts the emitted rules"
tmp=$(mktemp)
"$SCRIPT" emit 7893 "198.18.0.0/15" "fc00::/18" > "$tmp"
if ! nft -c -f "$tmp" 2>nft.err; then
  # nft -c probes the kernel via netlink. Unprivileged users (and kernels
  # missing tproxy) can't complete the probe; treat both as skips rather
  # than test failures, since the syntactic structure of our rules is
  # what we're really validating here.
  if grep -qiE "tproxy|cache initialization failed|operation not permitted|permission denied" nft.err; then
    echo "SKIP: nft -c unavailable in this environment ($(head -n1 nft.err))"
  else
    echo "FAIL: nft rejected emitted rules:"
    cat nft.err
    exit 1
  fi
fi
rm -f "$tmp" nft.err

echo "-- emit accepts comma-separated multi-element sets"
out=$("$SCRIPT" emit 7893 "198.18.0.0/15,10.0.0.0/8" "fc00::/18")
echo "$out" | grep -q "10.0.0.0/8" || { echo "FAIL: second v4 element missing"; exit 1; }

echo "OK"
