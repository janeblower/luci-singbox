#!/bin/sh
# Guards Bug 2: route.js must declare a tab and add base fields via taboption,
# matching the working inbounds/outbounds pattern (untabbed s.option breaks the
# GridSection modal once applyMaterialized injects match/action tabs).
set -eu
. "$(dirname "$0")/../lib/sb_helpers.sh"
F="${SB_VIEW}/tabs/route.js"
[ -f "$F" ] || { echo "FAIL: $F missing"; exit 1; }

# Route-rule section must pre-declare the match tab.
grep -q "s.tab('match'" "$F" || { echo "FAIL: route.js does not declare the 'match' tab"; exit 1; }
# Base fields (enabled/type) must be taboption, not bare option.
grep -q "s.taboption('match', form.Flag, 'enabled'" "$F" \
	|| { echo "FAIL: 'enabled' not added via taboption('match', ...)"; exit 1; }
grep -q "s.taboption('match', form.ListValue, 'type'" "$F" \
	|| { echo "FAIL: 'type' not added via taboption('match', ...)"; exit 1; }

# Rule-Sets section must declare its tab and use taboption too.
grep -q "s.tab('basic'" "$F" || { echo "FAIL: route.js does not declare the 'basic' tab (rule_set)"; exit 1; }
grep -q "s.taboption('basic', form.Flag, 'enabled'" "$F" \
	|| { echo "FAIL: rule_set 'enabled' not added via taboption('basic', ...)"; exit 1; }
grep -q "s.taboption('basic', form.ListValue, 'type'" "$F" \
	|| { echo "FAIL: rule_set 'type' not added via taboption('basic', ...)"; exit 1; }

# Regression lock: base fields must NOT be re-introduced as untabbed s.option().
grep -q "s.option(form.Flag, 'enabled'" "$F" \
	&& { echo "FAIL: base 'enabled' reverted to untabbed s.option()"; exit 1; } || true
grep -q "s.option(form.ListValue, 'type'" "$F" \
	&& { echo "FAIL: base 'type' reverted to untabbed s.option()"; exit 1; } || true

echo "PASS"
