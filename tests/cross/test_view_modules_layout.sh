#!/bin/sh
# tests/test_view_modules_layout.sh
# Verifies the modularized view layout under htdocs/luci-static/resources/view/singbox-ui/.
set -e
. "$(dirname "$0")/../lib/sb_helpers.sh"
ROOT="${SB_VIEW}"

REQUIRED="
$ROOT/main.js
$ROOT/lib/rpc.js
$ROOT/lib/common.js
$ROOT/importers/inbound.js
$ROOT/importers/outbound.js
$ROOT/importers/transport.js
$ROOT/tabs/inbounds.js
$ROOT/tabs/outbounds.js
$ROOT/tabs/route.js
$ROOT/tabs/dns.js
$ROOT/tabs/general.js
$ROOT/tabs/monitoring.js
$ROOT/widgets/action-bar.js
$ROOT/widgets/status-panel.js
"

fail=0
for f in $REQUIRED; do
  if [ ! -f "$f" ]; then
    echo "MISSING: $f"
    fail=1
  fi
done

# main.js must be small after the refactor.
lines=$(wc -l < "$ROOT/main.js")
if [ "$lines" -gt 220 ]; then
  echo "main.js too large: $lines lines (limit 220)"
  fail=1
fi

# No window.__sb_* globals after the refactor.
if grep -RHn "window\.__sb" "$ROOT" >/dev/null 2>&1; then
  echo "leftover window.__sb_* globals found"
  grep -RHn "window\.__sb" "$ROOT"
  fail=1
fi

# Phase C1: JSON import must not reload the page (it would discard
# the user's unsaved edits across other sections). Importer stages the
# new section into uci.state and shows ui.addNotification asking the
# user to press Save & Apply.
if grep -RnE 'window\.location\.reload\b|[^a-zA-Z_$]location\.reload\b' "$ROOT" >/dev/null 2>&1; then
  echo "FAIL: location.reload() found - Phase C1 forbids page reload from importer"
  grep -RnE 'window\.location\.reload\b|[^a-zA-Z_$]location\.reload\b' "$ROOT"
  fail=1
fi

# C2 D.1: the loadOutboundList alias was dead in inbounds/outbounds — it was
# imported but never called. Removing it shrinks the require graph and makes
# the next refactor easier.
if grep -nE 'var[[:space:]]+loadOutboundList[[:space:]]*=[[:space:]]*SbCommon\.loadOutboundList' \
   "$ROOT/tabs/inbounds.js" "$ROOT/tabs/outbounds.js" >/dev/null 2>&1; then
  echo "FAIL: dead loadOutboundList alias still present in inbounds/outbounds"
  grep -nE 'var[[:space:]]+loadOutboundList[[:space:]]*=[[:space:]]*SbCommon\.loadOutboundList' \
    "$ROOT/tabs/inbounds.js" "$ROOT/tabs/outbounds.js"
  fail=1
fi

# C2 D.4: main.js must not schedule wireTabs via setTimeout(fn, 0) — a
# microtask is enough and avoids the visible flicker.
if grep -nE 'setTimeout\(.*,[[:space:]]*0[[:space:]]*\)' "$ROOT/main.js" >/dev/null 2>&1; then
  echo "FAIL: setTimeout(fn, 0) still present in main.js (use Promise.resolve().then)"
  grep -nE 'setTimeout\(.*,[[:space:]]*0[[:space:]]*\)' "$ROOT/main.js"
  fail=1
fi

# Rule-sets are descriptor-driven (Route tab refactor): nft_rules is a field in
# the rule_set descriptors, not a hand-written form.Flag in a tab module.
if ! grep -q "nft_rules" "${SB_LIB}/builder/route/ruleset_remote.uc"; then
  echo "FAIL: nft_rules missing from rule_set remote descriptor"
  fail=1
fi

# C2 E.1: both Preview buttons in widgets/action-bar.js must route through
# showJsonModal with the {error|json} shape — no raw ui.showModal in the
# error path.
ACTION_BAR="$ROOT/widgets/action-bar.js"
if ! grep -qE '\{ ?error' "$ACTION_BAR"; then
  echo "FAIL: action-bar.js Preview generated config not using {error} shape"
  fail=1
fi
if grep -qE "ui\.showModal\(.*_\('Preview generated config'\)" "$ACTION_BAR"; then
  echo "FAIL: Preview generated config still calls ui.showModal directly (use showJsonModal)"
  fail=1
fi

# C2 E.2: withBusy helper must exist in lib/common.js and be exported.
COMMON="$ROOT/lib/common.js"
if ! grep -qE 'function[[:space:]]+withBusy\b' "$COMMON"; then
  echo "FAIL: lib/common.js does not define withBusy"
  fail=1
fi
if ! grep -qE 'withBusy:[[:space:]]*withBusy' "$COMMON"; then
  echo "FAIL: lib/common.js does not export withBusy"
  fail=1
fi

# C2 E.3: importers/inbound.js must no longer define its own fallbackCopy.
fallback_in_importers=$(grep -c 'function fallbackCopy' "$ROOT/importers/inbound.js" || true)
if [ "$fallback_in_importers" != "0" ]; then
  echo "FAIL: importers/inbound.js still defines fallbackCopy ($fallback_in_importers occurrences)"
  fail=1
fi

# C2 E.4: shared style.css must exist + be in the UI install manifest.
# (The Makefile and build-apk.sh both consume the per-package manifest —
# that file is the source of truth for what gets shipped, not per-file
# lines in the Makefile.)
UI_MANIFEST=scripts/install-manifest-luci-app-singbox-ui.txt
if [ ! -f "$ROOT/style.css" ]; then
  echo "FAIL: $ROOT/style.css missing"
  fail=1
fi
if ! grep -q 'style\.css' "$UI_MANIFEST"; then
  echo "FAIL: $UI_MANIFEST does not include style.css"
  fail=1
fi

# D1.8: build_constructor_for must remain dispatcher-only.
# Count total lines from `function build_constructor_for` to the next `^function`.
OUTBOUND_UC="${SB_LIB}/outbound.uc"
end_marker=$(grep -n '^function ' "$OUTBOUND_UC" | \
             awk -F: '$2 ~ /build_constructor_for/{found=1; next} found{print $1; exit}')
start=$(grep -n '^function build_constructor_for' "$OUTBOUND_UC" | cut -d: -f1)
total=$((end_marker - start))
if [ "$total" -gt 14 ]; then
  echo "FAIL build_constructor_for region too large ($total lines, expected ≤14)"
  fail=1
else
  echo "PASS build_constructor_for dispatcher region size ($total lines)"
fi

# D2.9 regression guard: per-protocol depends('type'|'protocol', ...) chains
# in tabs/outbounds.js and tabs/inbounds.js are forbidden for descriptor-owned
# proxy protocols. The descriptor-driven loop in each tab must be the only
# place per-protocol fields are wired.
#
# Allowed depends: those targeting non-proxy types only (interface, selector,
# urltest, subscription, url, json for outbound; tproxy, tun, direct for inbound).
#
# Bar: total `depends('type'|'protocol', '<proxy>')` occurrences in tabs/ must
# be zero for each of the descriptor-owned types. We grep for each name and
# count.

OUTBOUNDS=${SB_VIEW}/tabs/outbounds.js
INBOUNDS=${SB_VIEW}/tabs/inbounds.js

fail_depends=0
for proto in ssh trojan shadowsocks vless vmess hysteria2 tuic anytls; do
    n=$(grep -cE "depends\(['\"]type['\"], *['\"]${proto}['\"]\\)" "$OUTBOUNDS" || true)
    if [ "$n" -gt 0 ]; then
        echo "FAIL outbounds.js has $n hand-coded depends('type','${proto}') — must come from descriptor_form"
        fail_depends=1
    fi
done
for proto in trojan shadowsocks vless vmess hysteria2; do
    n=$(grep -cE "depends\(['\"]protocol['\"], *['\"]${proto}['\"]\\)" "$INBOUNDS" || true)
    if [ "$n" -gt 0 ]; then
        echo "FAIL inbounds.js has $n hand-coded depends('protocol','${proto}') — must come from descriptor_form"
        fail_depends=1
    fi
done

if [ "$fail_depends" -ne 0 ]; then
    fail=1
else
    echo "PASS depends-type/protocol guard (no per-proxy-protocol chains in tabs)"
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: view layout"
fi
exit $fail
