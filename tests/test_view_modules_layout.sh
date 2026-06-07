#!/bin/sh
# tests/test_view_modules_layout.sh
# Verifies the modularized view layout under htdocs/luci-static/resources/view/singbox-ui/.
set -e
ROOT="luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui"

REQUIRED="
$ROOT/main.js
$ROOT/lib/rpc.js
$ROOT/lib/common.js
$ROOT/importers/inbound.js
$ROOT/importers/outbound.js
$ROOT/tabs/inbounds.js
$ROOT/tabs/outbounds.js
$ROOT/tabs/rulesets.js
$ROOT/tabs/routing.js
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

# C2 D.7: rulesets.js nft_rules flag must have a description.
if ! awk '/o = s\.option\(form\.Flag, .nft_rules./{found=1} found && /o\.description/{print; exit 0} END{exit found?1:1}' \
   "$ROOT/tabs/rulesets.js" >/dev/null 2>&1; then
  # Fall back to a simpler grep: description string anywhere after nft_rules.
  if ! grep -nA5 "'nft_rules'" "$ROOT/tabs/rulesets.js" | grep -q 'o\.description'; then
    echo "FAIL: rulesets.js nft_rules form.Flag missing description"
    fail=1
  fi
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

# C2 E.4: shared style.css must exist + Makefile must install it.
if [ ! -f "$ROOT/style.css" ]; then
  echo "FAIL: $ROOT/style.css missing"
  fail=1
fi
if ! grep -q 'style.css' luci-app-singbox-ui/Makefile; then
  echo "FAIL: Makefile does not install style.css"
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: view layout"
fi
exit $fail
