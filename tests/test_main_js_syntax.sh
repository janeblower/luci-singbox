#!/bin/sh
# tests/test_main_js_syntax.sh
set -e

JS=luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/main.js

if [ ! -f "$JS" ]; then
  echo "FAIL: $JS not present"; exit 1
fi

# Skip cleanly inside containers (e.g. OpenWrt rootfs) that don't ship node.
if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 0
fi

# LuCI views are fragments — top-level `return` is invalid in standalone JS.
# Wrap them in a function for syntax checking. busybox mktemp has no --suffix,
# so create-and-rename to attach the .js extension.
tmp=$(mktemp)
mv "$tmp" "$tmp.js"
tmp="$tmp.js"
{
  echo "(function () {"
  cat "$JS"
  echo "});"
} > "$tmp"

if ! node --check "$tmp"; then
  echo "FAIL: JS syntax error"; rm -f "$tmp"; exit 1
fi
rm -f "$tmp"

echo "-- declares all expected requires"
grep -q "'require view'"          "$JS" || { echo "FAIL: missing 'require view'"; exit 1; }
grep -q "'require form'"          "$JS" || { echo "FAIL: missing 'require form'"; exit 1; }
grep -q "'require uci'"           "$JS" || { echo "FAIL: missing 'require uci'"; exit 1; }
grep -q "'require ui'"            "$JS" || { echo "FAIL: missing 'require ui'"; exit 1; }
grep -q "'require tools.widgets as widgets'" "$JS" || { echo "FAIL: missing 'require tools.widgets as widgets'"; exit 1; }

echo "-- references input UCI sections"
grep -q "fakeip"   "$JS" || { echo "FAIL: no fakeip section"; exit 1; }
grep -q "tproxy"   "$JS" || { echo "FAIL: no tproxy section"; exit 1; }

echo "-- references all three output GridSections"
grep -q "GridSection"           "$JS" || { echo "FAIL: no GridSection"; exit 1; }
grep -q "'outbound'"            "$JS" || { echo "FAIL: no outbound section type"; exit 1; }
grep -q "'ruleset'"             "$JS" || { echo "FAIL: no ruleset section type"; exit 1; }
grep -q "'route_rule'"          "$JS" || { echo "FAIL: no route_rule section type"; exit 1; }
grep -q "modaltitle"            "$JS" || { echo "FAIL: no modaltitle"; exit 1; }

echo "-- references new outbound proxy types"
grep -q "'json'"                 "$JS" || { echo "FAIL: no proxy_type=json"; exit 1; }
grep -q "'subscription'"         "$JS" || { echo "FAIL: no proxy_type=subscription"; exit 1; }
grep -q "proxy_json"             "$JS" || { echo "FAIL: no proxy_json field"; exit 1; }
grep -q "sub_url"                "$JS" || { echo "FAIL: no sub_url field"; exit 1; }
grep -q "sub_update_via"         "$JS" || { echo "FAIL: no sub_update_via field"; exit 1; }
grep -q "sub_interval"           "$JS" || { echo "FAIL: no sub_interval field"; exit 1; }
grep -q "form.TextValue"         "$JS" || { echo "FAIL: no form.TextValue widget"; exit 1; }

echo "-- references ruleset fields"
grep -q "nft_rules"              "$JS" || { echo "FAIL: no nft_rules field"; exit 1; }
grep -q "update_interval"        "$JS" || { echo "FAIL: no update_interval field"; exit 1; }

echo "-- references DNS tab sections"
grep -q "'dns_server'"          "$JS" || { echo "FAIL: no dns_server section type"; exit 1; }
grep -q "'dns_rule'"            "$JS" || { echo "FAIL: no dns_rule section type"; exit 1; }
grep -q "data-tab.*dns"         "$JS" || { echo "FAIL: no dns tab marker"; exit 1; }

echo "-- references Monitoring tab"
grep -q "buildMonitoring"        "$JS" || { echo "FAIL: no buildMonitoring"; exit 1; }
grep -q "callClash"              "$JS" || { echo "FAIL: no callClash wrapper"; exit 1; }
grep -q "clash_request"          "$JS" || { echo "FAIL: no clash_request method"; exit 1; }
grep -q "data-tab.*monitoring"   "$JS" || { echo "FAIL: no monitoring tab marker"; exit 1; }

echo "-- has sub-tab data-tab markers"
grep -q "data-tab.*outbounds"    "$JS" || { echo "FAIL: no outbounds sub-tab marker"; exit 1; }
grep -q "data-tab.*rulesets"     "$JS" || { echo "FAIL: no rulesets sub-tab marker"; exit 1; }
grep -q "data-tab.*routerules"   "$JS" || { echo "FAIL: no routerules sub-tab marker"; exit 1; }

echo "-- has handleSaveApply via ui.changes.apply"
grep -q "handleSaveApply"  "$JS" || { echo "FAIL: no handleSaveApply"; exit 1; }
grep -q "ui.changes.apply" "$JS" || { echo "FAIL: no ui.changes.apply call (needed for /admin/uci/apply_rollback)"; exit 1; }
grep -q "'enabled'"        "$JS" || { echo "FAIL: no enabled flag"; exit 1; }

echo "-- references General tab sections"
grep -q "'cache'"               "$JS" || { echo "FAIL: no cache section type"; exit 1; }
grep -q "'log'"                 "$JS" || { echo "FAIL: no log section type"; exit 1; }
grep -q "data-tab.*general"     "$JS" || { echo "FAIL: no general tab marker"; exit 1; }

echo "OK"
