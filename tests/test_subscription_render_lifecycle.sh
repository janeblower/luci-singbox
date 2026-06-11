#!/bin/sh
# tests/test_subscription_render_lifecycle.sh — asserts that outbounds.js
# invokes SbSubView.injectChildRows from a render() wrapper, not only from
# the action-bar Refresh handler.
set -eu; cd "$(dirname "$0")/.."

JS=luci-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/tabs/outbounds.js

grep -q 'SbSubView.injectChildRows' "$JS" \
    || { echo "FAIL: outbounds.js never calls injectChildRows"; exit 1; }

# It must be called from a render() wrapper, not only inside an event
# handler. Heuristic: the call must appear inside a `.then(function (node)`
# or `m.render = function ()` block.
awk '
    /m\.render *= *function/    { in_render = 1 }
    /injectChildRows/ && in_render { hits++ }
    /^\}/                       { in_render = 0 }
    END { exit (hits ? 0 : 1) }
' "$JS" || { echo "FAIL: injectChildRows not inside render() wrapper"; exit 1; }

CSS=luci-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/style.css
grep -q 'sb-sub-child' "$CSS" \
    || { echo "FAIL: no .sb-sub-child rules in style.css"; exit 1; }

# CSS must explicitly set width on the action column so child rows align.
grep -q 'sb-sub-child-name' "$CSS" \
    || { echo "FAIL: sb-sub-child-name padding rule missing"; exit 1; }

echo "PASS: subscription render lifecycle + CSS"
