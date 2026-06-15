#!/bin/sh
# tests/test_main_js_syntax.sh
set -e

JS=luci-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/main.js

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
# fakeip lives in tabs/dns.js after modularization (Task 11)
DNS_TAB=luci-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/tabs/dns.js
grep -q "fakeip"   "$DNS_TAB" || { echo "FAIL: no fakeip section (checked tabs/dns.js)"; exit 1; }
# tproxy lives in tabs/inbounds.js after modularization (Task 7)
INBOUNDS_TAB=luci-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/tabs/inbounds.js
grep -q "tproxy"   "$INBOUNDS_TAB" || { echo "FAIL: no tproxy section (checked tabs/inbounds.js)"; exit 1; }

echo "-- references all three output GridSections"
# GridSection usage lives in extracted tab modules after modularization
DNS_TAB=luci-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/tabs/dns.js
( grep -q "GridSection" "$JS" || grep -q "GridSection" "$DNS_TAB" ) || { echo "FAIL: no GridSection"; exit 1; }
# 'outbound', 'ruleset', 'route_rule' live in tabs/route.js after route-tab refactor
ROUTE_TAB=luci-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/tabs/route.js
grep -q "'outbound'"            "$ROUTE_TAB" || { echo "FAIL: no outbound section type (checked tabs/route.js)"; exit 1; }
grep -q "'ruleset'"             "$ROUTE_TAB" || { echo "FAIL: no ruleset section type (checked tabs/route.js)"; exit 1; }
grep -q "'route_rule'"          "$ROUTE_TAB" || { echo "FAIL: no route_rule section type (checked tabs/route.js)"; exit 1; }
# modaltitle lives in extracted tab modules after modularization
ROUTE_TAB=luci-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/tabs/route.js
DNS_TAB=luci-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/tabs/dns.js
( grep -q "modaltitle" "$JS" || grep -q "modaltitle" "$ROUTE_TAB" || grep -q "modaltitle" "$DNS_TAB" ) || { echo "FAIL: no modaltitle"; exit 1; }

echo "-- references new outbound types (merged type field)"
# These fields live in tabs/outbounds.js after modularization (Task 8)
OUTBOUNDS_TAB=luci-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/tabs/outbounds.js
grep -q "'vless'"                "$OUTBOUNDS_TAB" || { echo "FAIL: no type=vless (checked tabs/outbounds.js)"; exit 1; }
grep -q "'subscription'"         "$OUTBOUNDS_TAB" || { echo "FAIL: no type=subscription (checked tabs/outbounds.js)"; exit 1; }
# E2: proxy_url (share-link URL type) replaced by openShareLinkModal import button.
grep -q "openShareLinkModal"     "$OUTBOUNDS_TAB" || { echo "FAIL: no openShareLinkModal (checked tabs/outbounds.js)"; exit 1; }
grep -q "sub_url"                "$OUTBOUNDS_TAB" || { echo "FAIL: no sub_url field (checked tabs/outbounds.js)"; exit 1; }
grep -q "sub_user_agent"         "$OUTBOUNDS_TAB" || { echo "FAIL: no sub_user_agent field (checked tabs/outbounds.js)"; exit 1; }
grep -q "sub_update_via"         "$OUTBOUNDS_TAB" && { echo "FAIL: sub_update_via should be removed"; exit 1; } || true
grep -q "sub_interval"           "$OUTBOUNDS_TAB" || { echo "FAIL: no sub_interval field (checked tabs/outbounds.js)"; exit 1; }
! grep -q "proxy_type"           "$JS" || { echo "FAIL: legacy proxy_type still present"; exit 1; }
! grep -q "'json'"               "$JS" || { echo "FAIL: legacy json outbound type still present"; exit 1; }

echo "-- references ruleset fields (descriptor-driven)"
RS_REMOTE=luci-singbox-ui/root/usr/share/singbox-ui/lib/builder/route/ruleset_remote.uc
grep -q "nft_rules"       "$RS_REMOTE" || { echo "FAIL: no nft_rules field (checked builder/route/ruleset_remote.uc)"; exit 1; }
grep -q "update_interval" "$RS_REMOTE" || { echo "FAIL: no update_interval field (checked builder/route/ruleset_remote.uc)"; exit 1; }
# rule-sets are descriptor-driven in tabs/route.js
ROUTE_TAB=luci-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/tabs/route.js
grep -q "applyMaterialized" "$ROUTE_TAB" || { echo "FAIL: route.js must use descriptor_form.applyMaterialized"; exit 1; }

echo "-- references DNS tab sections"
# dns_server, dns_rule, descriptor-driven fields, default_resolver live in tabs/dns.js after modularization (Task 11)
DNS_TAB=luci-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/tabs/dns.js
grep -q "'dns_server'"          "$DNS_TAB" || { echo "FAIL: no dns_server section type (checked tabs/dns.js)"; exit 1; }
grep -q "'dns_rule'"            "$DNS_TAB" || { echo "FAIL: no dns_rule section type (checked tabs/dns.js)"; exit 1; }
grep -q "data-tab.*dns"         "$JS" || { echo "FAIL: no dns tab marker"; exit 1; }
# detour for dns_server must be a dropdown of existing outbounds. Since WS4 Task B4
# the dns server section is descriptor-driven: detour carries dynamic:'outbounds' in
# the descriptor, so descriptor_form.attachDynamic renders it as a ListValue populated
# from UCI outbound sections. Verify the descriptor-driven path is wired up.
grep -q "applyMaterialized"     "$DNS_TAB" || { echo "FAIL: dns.js must use descriptor_form.applyMaterialized for descriptor-driven fields (checked tabs/dns.js)"; exit 1; }
grep -q "dnsSchema"             "$DNS_TAB" || { echo "FAIL: dns.js must read dnsSchema from SbViewState (checked tabs/dns.js)"; exit 1; }
grep -q "'default_resolver'"    "$DNS_TAB" || { echo "FAIL: dns.default_resolver UI option missing (checked tabs/dns.js)"; exit 1; }

echo "-- references Monitoring tab"
grep -q "buildMonitoring"        "$JS" || { echo "FAIL: no buildMonitoring"; exit 1; }
# clash_request was split into clash_get + clash_mutate (C1 Task 4). lib/rpc.js
# must declare BOTH wrappers (and the RPC method names they bind to).
LIB_RPC=luci-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/lib/rpc.js
[ -f "$LIB_RPC" ] || { echo "FAIL: $LIB_RPC missing"; exit 1; }
grep -q "callClashGet"    "$LIB_RPC" || { echo "FAIL: no callClashGet wrapper in lib/rpc.js"; exit 1; }
grep -q "callClashMutate" "$LIB_RPC" || { echo "FAIL: no callClashMutate wrapper in lib/rpc.js"; exit 1; }
grep -q "clash_get"       "$LIB_RPC" || { echo "FAIL: no clash_get method in lib/rpc.js"; exit 1; }
grep -q "clash_mutate"    "$LIB_RPC" || { echo "FAIL: no clash_mutate method in lib/rpc.js"; exit 1; }
# Legacy clash_request name must NOT remain anywhere in the view tree.
! grep -q "clash_request" "$LIB_RPC" || { echo "FAIL: legacy clash_request still in lib/rpc.js"; exit 1; }
grep -q "data-tab.*monitoring"   "$JS" || { echo "FAIL: no monitoring tab marker"; exit 1; }

echo "-- has sub-tab data-tab markers"
grep -q "data-tab.*outbounds"    "$JS" || { echo "FAIL: no outbounds sub-tab marker"; exit 1; }
grep -q "data-tab.*rulesets"     "$JS" || { echo "FAIL: no rulesets sub-tab marker"; exit 1; }
grep -q "data-tab.*routerules"   "$JS" || { echo "FAIL: no routerules sub-tab marker"; exit 1; }

echo "-- has handleSaveApply via ui.changes.apply"
grep -q "handleSaveApply"  "$JS" || { echo "FAIL: no handleSaveApply"; exit 1; }
grep -q "ui.changes.apply" "$JS" || { echo "FAIL: no ui.changes.apply call (needed for /admin/uci/apply_rollback)"; exit 1; }
# 'enabled' flag lives in extracted tab modules after modularization
GENERAL_TAB=luci-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/tabs/general.js
( grep -q "'enabled'" "$JS" || grep -q "'enabled'" "$GENERAL_TAB" ) || { echo "FAIL: no enabled flag"; exit 1; }

echo "-- references General tab sections"
# 'cache' and 'log' live in tabs/general.js after modularization (Task 12)
GENERAL_TAB=luci-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/tabs/general.js
grep -q "'cache'"               "$GENERAL_TAB" || { echo "FAIL: no cache section type (checked tabs/general.js)"; exit 1; }
grep -q "'log'"                 "$GENERAL_TAB" || { echo "FAIL: no log section type (checked tabs/general.js)"; exit 1; }
grep -q "data-tab.*general"     "$JS" || { echo "FAIL: no general tab marker"; exit 1; }

echo "OK"
