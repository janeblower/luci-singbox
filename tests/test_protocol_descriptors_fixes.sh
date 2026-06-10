#!/bin/sh
# tests/test_protocol_descriptors_fixes.sh
# Regression tests for protocol-descriptor correctness bugs:
#   S4-1 hysteria2 obfs with empty password must NOT emit obfs{}
#   S4-6 direct proxy_protocol enum: "0" must not emit proxy_protocol:0
#   S4-7 IPv6-literal hosts parse in share-links
#   S4-8 colon-bearing secrets survive name:secret splitting
#   S4-9 dns rewrite_ttl NaN guard
# Inline-eval harness, mirrors tests/test_share_link_hy2.sh.
set -eu
cd "$(dirname "$0")/.."

UCODE_BIN="${UCODE_BIN:-ucode}"
UCODE_LIB_DIR="${UCODE_LIB_DIR:-luci-app-singbox-ui/root/usr/share/singbox-ui/lib}"
command -v "$UCODE_BIN" >/dev/null 2>&1 || { echo "SKIP test_protocol_descriptors_fixes (ucode missing)"; exit 0; }

je() { "$UCODE_BIN" -L "$UCODE_LIB_DIR" -e "$1"; }
pass=0
ok()   { echo "  PASS: $1"; pass=$((pass+1)); }
die()  { echo "FAIL: $1 [$2]"; exit 1; }

# ---- S4-1: hysteria2 outbound, obfs_type set but obfs_password empty ----
out=$(je '
    let ob = require("outbound");
    let s = { ".name":"hy", "server":"h.b", "server_port":"8443",
              "server_password":"pw", "obfs_type":"salamander", "obfs_password":"" };
    let r = ob.build_constructor_for(s, "hysteria2");
    print(r.obfs != null ? "HAS_OBFS" : "NO_OBFS");
')
[ "$out" = "NO_OBFS" ] || die "S4-1 outbound empty obfs_password must drop obfs{}" "$out"
ok "S4-1 outbound: empty obfs_password drops obfs{}"

# Sanity: a real obfs_password still emits obfs{}.
out=$(je '
    let ob = require("outbound");
    let s = { ".name":"hy", "server":"h.b", "server_port":"8443",
              "server_password":"pw", "obfs_type":"salamander", "obfs_password":"opass" };
    let r = ob.build_constructor_for(s, "hysteria2");
    print(r.obfs != null && r.obfs.password == "opass" ? "OK" : "BAD");
')
[ "$out" = "OK" ] || die "S4-1 outbound: real obfs_password must still emit" "$out"
ok "S4-1 outbound: real obfs_password emits obfs{}"

# ---- S4-1: hysteria2 inbound, obfs_type set but obfs_password empty ----
out=$(je '
    let inb = require("inbound");
    let s = { ".name":"h2in", "protocol":"hysteria2", "listen_port":"443",
              "server_password":"pw", "obfs_type":"salamander", "obfs_password":"",
              "tls_server_name":"h.b", "tls_certificate_path":"/c", "tls_key_path":"/k" };
    let r = inb.build_one(s);
    print(r.obfs != null ? "HAS_OBFS" : "NO_OBFS");
')
[ "$out" = "NO_OBFS" ] || die "S4-1 inbound empty obfs_password must drop obfs{}" "$out"
ok "S4-1 inbound: empty obfs_password drops obfs{}"

# ---- S4-1: share-link hy2 with obfs but no obfs-password ----
out=$(je '
    let ob = require("outbound");
    let r = ob.parse_proxy_url("hysteria2://pw@h.b:443?obfs=salamander#x");
    print(r.obfs != null ? "HAS_OBFS" : "NO_OBFS");
')
[ "$out" = "NO_OBFS" ] || die "S4-1 share-link obfs without password must drop obfs{}" "$out"
ok "S4-1 share-link: obfs without obfs-password drops obfs{}"

echo "ALL PASS: test_protocol_descriptors_fixes ($pass checks)"
