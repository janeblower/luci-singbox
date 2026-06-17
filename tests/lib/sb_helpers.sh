# shellcheck shell=sh
# shellcheck disable=SC2034  # vars are consumed by the tests that source this file
# tests/lib/sb_helpers.sh — single source of truth for source-tree paths used by
# the shell test suite. Sourced by tests that locate package source. All paths
# are relative to the repo root (tests run with CWD=repo root) and overridable
# via env so the tree can move without touching test bodies. Backend lives in
# singbox-ui/; UI (htdocs + menu.d + acl.d) and i18n (po) live in
# luci-app-singbox-ui/ — the three-package split.
: "${SB_BACKEND_ROOT:=singbox-ui/root}"
: "${SB_UI_ROOT:=luci-app-singbox-ui/root}"
: "${SB_UI_HTDOCS:=luci-app-singbox-ui/htdocs}"
: "${SB_PO_DIR:=luci-app-singbox-ui/po}"
SB_SHARE="$SB_BACKEND_ROOT/usr/share/singbox-ui"
SB_LIB="$SB_SHARE/lib"
SB_RPCD="$SB_BACKEND_ROOT/usr/libexec/rpcd/singbox-ui"
SB_ACL="$SB_UI_ROOT/usr/share/rpcd/acl.d/luci-singbox-ui.json"
SB_MENU="$SB_UI_ROOT/usr/share/luci/menu.d/luci-singbox-ui.json"
SB_VIEW="$SB_UI_HTDOCS/luci-static/resources/view/singbox-ui"
sb_ucode() { "${UCODE_BIN:-ucode}" -L "$SB_LIB" "$@"; }
