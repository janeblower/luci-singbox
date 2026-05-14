#!/bin/sh
# tests/test_main_js_syntax.sh
set -e

JS=luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/main.js

if [ ! -f "$JS" ]; then
  echo "FAIL: $JS not present"; exit 1
fi

# LuCI views are fragments — top-level `return` is invalid in standalone JS.
# Wrap them in a function for syntax checking.
tmp=$(mktemp --suffix=.js)
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
grep -q "'require rpc'"           "$JS" || { echo "FAIL: missing 'require rpc'"; exit 1; }
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
grep -q "TextareaValue"          "$JS" || { echo "FAIL: no TextareaValue custom widget"; exit 1; }

echo "-- references ruleset fields"
grep -q "dns_fakeip"             "$JS" || { echo "FAIL: no dns_fakeip field"; exit 1; }
grep -q "nft_rules"              "$JS" || { echo "FAIL: no nft_rules field"; exit 1; }
grep -q "update_interval"        "$JS" || { echo "FAIL: no update_interval field"; exit 1; }

echo "-- has sub-tab data-tab markers"
grep -q "data-tab.*outbounds"    "$JS" || { echo "FAIL: no outbounds sub-tab marker"; exit 1; }
grep -q "data-tab.*rulesets"     "$JS" || { echo "FAIL: no rulesets sub-tab marker"; exit 1; }
grep -q "data-tab.*routerules"   "$JS" || { echo "FAIL: no routerules sub-tab marker"; exit 1; }

echo "-- wires the restart rpc method"
grep -q "singbox-ui.*restart" "$JS" || { echo "FAIL: no restart rpc binding"; exit 1; }

echo "-- has handleSaveApply with uci.apply and enabled flag"
grep -q "handleSaveApply" "$JS" || { echo "FAIL: no handleSaveApply"; exit 1; }
grep -q "uci.apply"       "$JS" || { echo "FAIL: no uci.apply call"; exit 1; }
grep -q "uci.changes"     "$JS" || { echo "FAIL: no uci.changes check"; exit 1; }
grep -q "'enabled'"       "$JS" || { echo "FAIL: no enabled flag"; exit 1; }

echo "OK"
