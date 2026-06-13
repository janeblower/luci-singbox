#!/bin/sh
set -eu
F="luci-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/tabs/outbounds.js"
# The via field must list ALL outbounds (excluding subscriptions + self),
# not only type==='direct' ones.
grep -A14 "sub_update_via" "$F" | grep -qE "sec\.type ([!=]=+) 'subscription'" \
  || { echo "FAIL: via field does not exclude subscription-type outbounds / not reworked"; exit 1; }
# It must NOT gate option inclusion on type==='direct' anymore.
if grep -A14 "sub_update_via" "$F" | grep -qE "sec\.type ===? 'direct'"; then
  echo "FAIL: via field still filters to direct-only outbounds"; exit 1; fi
echo "PASS"
