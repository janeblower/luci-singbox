#!/bin/sh
# tests/test_eye_toggle.sh
# Static guards for the E1 eye-toggle replacement of D3 reveal tokens.
set -e
cd "$(dirname "$0")/.."

DF=luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/lib/descriptor_form.js
fail=0

if ! grep -q 'function decorateSecretInput' "$DF"; then
    echo "FAIL: decorateSecretInput not defined in descriptor_form.js"
    fail=1
fi

if ! grep -q 'decorateSecretInput(opt)' "$DF"; then
    echo "FAIL: decorateSecretInput not invoked from applyMaterialized"
    fail=1
fi

# Nothing in the view tree may still reference the deleted reveal-token machinery.
VIEW_ROOT=luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui
hits=$(grep -rn -E 'revealGrant|revealRevoke|withRevealToken|singboxUiRevealToken|reveal_token' "$VIEW_ROOT" 2>/dev/null || true)
if [ -n "$hits" ]; then
    echo "FAIL: reveal-token references still present in view/:"
    echo "$hits"
    fail=1
fi

# Nothing in the lib tree may still require reveal.uc / scrub.uc.
hits=$(grep -rn -E 'require\("reveal"\)|require\("scrub"\)|reveal\.uc|scrub\.uc' \
    luci-app-singbox-ui/root/usr/share/singbox-ui/ \
    luci-app-singbox-ui/root/usr/libexec/ 2>/dev/null || true)
if [ -n "$hits" ]; then
    echo "FAIL: server-side reveal/scrub references still present:"
    echo "$hits"
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "PASS test_eye_toggle"
fi
exit $fail
