#!/bin/sh
# Guards Bug 2: route.js must declare a tab and add base fields via taboption,
# matching the working inbounds/outbounds pattern (untabbed s.option breaks the
# GridSection modal once applyMaterialized injects match/action tabs).
set -eu
F="luci-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/tabs/route.js"
[ -f "$F" ] || { echo "FAIL: $F missing"; exit 1; }

# Route-rule section must pre-declare the match tab.
grep -q "s.tab('match'" "$F" || { echo "FAIL: route.js does not declare the 'match' tab"; exit 1; }
# Base fields (enabled/type) must be taboption, not bare option.
grep -q "s.taboption('match', form.Flag, 'enabled'" "$F" \
	|| { echo "FAIL: 'enabled' not added via taboption('match', ...)"; exit 1; }
grep -q "s.taboption('match', form.ListValue, 'type'" "$F" \
	|| { echo "FAIL: 'type' not added via taboption('match', ...)"; exit 1; }
echo "PASS"
