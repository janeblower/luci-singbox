#!/bin/sh
set -eu; cd "$(dirname "$0")/.."
UCODE_BIN="${UCODE_BIN:-ucode}"
UCODE_LIB_DIR="${UCODE_LIB_DIR:-luci-singbox-ui/root/usr/share/singbox-ui/lib}"
command -v "$UCODE_BIN" >/dev/null 2>&1 || { echo "SKIP test_share_link_hy2"; exit 0; }

je() { "$UCODE_BIN" -L "$UCODE_LIB_DIR" -e "$1"; }

# hysteria2:// full URL — password, host, port, obfs
out=$(je '
    let o = require("outbound");
    let r = o.parse_proxy_url("hysteria2://hy2pass@example.com:443?obfs=salamander&obfs-password=opass#hy2srv");
    print(sprintf("%s|%s|%d|%s|%s|%s", r.type, r.server, r.server_port, r.password, r.obfs.type, r.obfs.password));
')
[ "$out" = "hysteria2|example.com|443|hy2pass|salamander|opass" ] \
    || { echo "FAIL: hysteria2:// parse [$out]"; exit 1; }

# hy2:// short scheme alias
out=$(je '
    let o = require("outbound");
    let r = o.parse_proxy_url("hy2://secret@10.0.0.1:8443#mynode");
    print(sprintf("%s|%s|%d|%s", r.type, r.server, r.server_port, r.password));
')
[ "$out" = "hysteria2|10.0.0.1|8443|secret" ] \
    || { echo "FAIL: hy2:// alias parse [$out]"; exit 1; }

echo "PASS: hy2 share-link parser"
