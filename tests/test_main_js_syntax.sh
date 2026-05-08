#!/bin/sh
# tests/test_main_js_syntax.sh
set -e

JS=htdocs/luci-static/resources/view/sing-box/main.js

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
grep -q "'require view'"   "$JS" || { echo "FAIL: missing 'require view'"; exit 1; }
grep -q "'require form'"   "$JS" || { echo "FAIL: missing 'require form'"; exit 1; }
grep -q "'require uci'"    "$JS" || { echo "FAIL: missing 'require uci'"; exit 1; }
grep -q "'require rpc'"    "$JS" || { echo "FAIL: missing 'require rpc'"; exit 1; }
grep -q "'require ui'"     "$JS" || { echo "FAIL: missing 'require ui'"; exit 1; }
grep -q "'require network'" "$JS" || { echo "FAIL: missing 'require network'"; exit 1; }

echo "-- references all three UCI sections"
grep -q "fakeip"   "$JS" || { echo "FAIL: no fakeip section"; exit 1; }
grep -q "tproxy"   "$JS" || { echo "FAIL: no tproxy section"; exit 1; }
grep -q "nftables" "$JS" || { echo "FAIL: no nftables section"; exit 1; }

echo "-- wires the rpcd methods"
grep -q "sing-box.*generate"  "$JS" || { echo "FAIL: no generate rpc binding"; exit 1; }
grep -q "sing-box.*nftables"  "$JS" || { echo "FAIL: no nftables rpc binding"; exit 1; }

echo "OK"
