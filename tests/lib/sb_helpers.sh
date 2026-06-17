# tests/lib/sb_helpers.sh — single source of truth for source-tree paths used by
# the shell test suite. Sourced by tests that locate package source. All paths
# are relative to the repo root (tests run with CWD=repo root) and overridable
# via env so the tree can move without touching test bodies. The four defaults
# below are flipped to the post-move package dirs in a later phase; nothing else
# changes.
: "${SB_BACKEND_ROOT:=luci-singbox-ui/root}"
: "${SB_UI_ROOT:=luci-singbox-ui/root}"
: "${SB_UI_HTDOCS:=luci-singbox-ui/htdocs}"
: "${SB_PO_DIR:=luci-singbox-ui/po}"
SB_SHARE="$SB_BACKEND_ROOT/usr/share/singbox-ui"
SB_LIB="$SB_SHARE/lib"
SB_RPCD="$SB_BACKEND_ROOT/usr/libexec/rpcd/singbox-ui"
SB_ACL="$SB_UI_ROOT/usr/share/rpcd/acl.d/luci-singbox-ui.json"
SB_MENU="$SB_UI_ROOT/usr/share/luci/menu.d/luci-singbox-ui.json"
SB_VIEW="$SB_UI_HTDOCS/luci-static/resources/view/singbox-ui"
sb_ucode() { "${UCODE_BIN:-ucode}" -L "$SB_LIB" "$@"; }
