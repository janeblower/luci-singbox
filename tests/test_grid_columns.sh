#!/bin/sh
# tests/test_grid_columns.sh
# Static guard: every taboption('basic', ...) in tabs/outbounds.js and
# tabs/inbounds.js must either be one of the whitelisted column names or
# have modalonly=true on one of the next 5 lines.
set -e
cd "$(dirname "$0")/.."

WHITELIST='enabled _export _address type protocol __rename'

check_file() {
    file="$1"
    fail=0
    line_nos=$(grep -n "s\\.taboption(.basic." "$file" | cut -d: -f1)
    for ln in $line_nos; do
        line=$(sed -n "${ln}p" "$file")
        # Extract the field name as 3rd comma-separated arg, stripped of quotes/whitespace.
        name=$(echo "$line" | sed -n "s/.*taboption([^,]*,[^,]*, *['\"]\\([^'\"]*\\)['\"].*/\\1/p")
        if echo " $WHITELIST " | grep -q " $name "; then
            continue
        fi
        # Check next 5 lines for modalonly = true
        next=$(sed -n "$((ln+1)),$((ln+5))p" "$file")
        if echo "$next" | grep -q 'modalonly *= *true'; then
            continue
        fi
        echo "FAIL $file:$ln field '$name' is neither whitelisted nor modalonly=true"
        fail=1
    done
    return $fail
}

fail=0
check_file luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/tabs/outbounds.js || fail=1
check_file luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/tabs/inbounds.js  || fail=1
[ "$fail" -eq 0 ] && echo "PASS test_grid_columns"
exit $fail
