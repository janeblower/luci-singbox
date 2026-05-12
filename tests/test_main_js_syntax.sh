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

echo "-- references outbound TypedSection"
grep -q "outbound" "$JS" || { echo "FAIL: no outbound TypedSection"; exit 1; }

echo "-- wires the restart rpc method"
grep -q "singbox-ui.*restart" "$JS" || { echo "FAIL: no restart rpc binding"; exit 1; }

echo "-- has handleSaveApply"
grep -q "handleSaveApply" "$JS" || { echo "FAIL: no handleSaveApply"; exit 1; }

echo "OK"
