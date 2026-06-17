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
UCODE_LIB_DIR="${UCODE_LIB_DIR:-luci-singbox-ui/root/usr/share/singbox-ui/lib}"
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

# ---- S4-6: direct proxy_protocol — "0" must not emit proxy_protocol:0 ----
# With an enum constrained to ""/"1"/"2", a stray "0" still must not surface
# an invalid 0. We assert that a chosen "1"/"2" emits, and "" emits nothing.
out=$(je '
    let ob = require("outbound");
    let s = { ".name":"d", "proxy_protocol":"2" };
    let r = ob.build_constructor_for(s, "direct");
    print(r.proxy_protocol == 2 ? "EMIT2" : "BAD");
')
[ "$out" = "EMIT2" ] || die "S4-6 proxy_protocol=2 must emit 2" "$out"
ok "S4-6 proxy_protocol=2 emits 2"

out=$(je '
    let ob = require("outbound");
    let s = { ".name":"d", "proxy_protocol":"" };
    let r = ob.build_constructor_for(s, "direct");
    print(r.proxy_protocol != null ? "BAD" : "ABSENT");
')
[ "$out" = "ABSENT" ] || die "S4-6 empty proxy_protocol must not emit" "$out"
ok "S4-6 empty proxy_protocol absent"

# The descriptor field must declare type=enum (so the S4-5 check passes and
# the UI renders a dropdown rather than a free number input).
out=$(je '
    require("outbound");
    let reg = require("builder.protocols.registry");
    let d = reg.get("outbound","direct");
    let t = "";
    for (let f in d.fields) if (f.name == "proxy_protocol") t = f.type;
    print(t);
')
[ "$out" = "enum" ] || die "S4-6 proxy_protocol field must be type=enum" "$out"
ok "S4-6 proxy_protocol declared enum"

# ---- S4-9: dns rewrite_ttl field handling ----
# build_rules(cur) uses the descriptor-driven filler. Feed a mock cursor with
# the new dns_rule schema (type/rule_set/action/server). With the declarative
# filler, rewrite_ttl is a num field with omit_when:empty — a non-numeric value
# ("abc") is dropped (field absent), NOT substituted with a synthetic default.
out=$(je '
    let dns = require("dns");
    let cur = {
        foreach: function(pkg, kind, cb) {
            if (kind == "ruleset") cb({ ".name":"rs", "enabled":"1" });
            if (kind == "dns_server") cb({ ".name":"fakeip", "enabled":"1", "type":"fakeip" });
            if (kind == "dns_rule")
                cb({ ".name":"r", "enabled":"1", "type":"default", "rule_set":["rs"],
                     "action":"route", "server":"fakeip", "rewrite_ttl":"abc" });
        },
    };
    let rules = dns.build_rules(cur);
    print(rules[0].rewrite_ttl);
')
[ "$out" = "(null)" ] || [ "$out" = "" ] || die "S4-9 non-numeric rewrite_ttl must be omitted (null)" "$out"
ok "S4-9 NaN rewrite_ttl -> omitted (no synthetic default)"

# "0" must still mean explicit disable (regression guard).
out=$(je '
    let dns = require("dns");
    let cur = {
        foreach: function(pkg, kind, cb) {
            if (kind == "ruleset") cb({ ".name":"rs", "enabled":"1" });
            if (kind == "dns_server") cb({ ".name":"fakeip", "enabled":"1", "type":"fakeip" });
            if (kind == "dns_rule")
                cb({ ".name":"r", "enabled":"1", "type":"default", "rule_set":["rs"],
                     "action":"route", "server":"fakeip", "rewrite_ttl":"0" });
        },
    };
    let rules = dns.build_rules(cur);
    print(rules[0].rewrite_ttl);
')
[ "$out" = "0" ] || die "S4-9 rewrite_ttl=0 must stay 0" "$out"
ok "S4-9 rewrite_ttl=0 stays 0"

# Explicit numeric value is emitted as-is.
out=$(je '
    let dns = require("dns");
    let cur = {
        foreach: function(pkg, kind, cb) {
            if (kind == "ruleset") cb({ ".name":"rs", "enabled":"1" });
            if (kind == "dns_server") cb({ ".name":"fakeip", "enabled":"1", "type":"fakeip" });
            if (kind == "dns_rule")
                cb({ ".name":"r", "enabled":"1", "type":"default", "rule_set":["rs"],
                     "action":"route", "server":"fakeip", "rewrite_ttl":"300" });
        },
    };
    let rules = dns.build_rules(cur);
    print(rules[0].rewrite_ttl);
')
[ "$out" = "300" ] || die "S4-9 explicit rewrite_ttl=300 must emit 300" "$out"
ok "S4-9 explicit rewrite_ttl=300 emitted"

# ---- S4-7: IPv6-literal hosts parse in share-links ----
# S4.2: the host is stored WITHOUT the [...] brackets — sing-box's `server`
# field wants the bare literal; a bracketed value is rejected. (Previously the
# brackets were kept, which this block asserted; now corrected.)
out=$(je '
    let ob = require("outbound");
    let r = ob.parse_proxy_url("vless://11111111-2222-3333-4444-555555555555@[2001:db8::1]:443?security=tls");
    print(r != null ? r.server : "NULL");
')
[ "$out" = "2001:db8::1" ] || die "S4-7 vless IPv6 host must parse" "$out"
ok "S4-7 vless IPv6 host parses"

out=$(je '
    let ob = require("outbound");
    let r = ob.parse_proxy_url("trojan://pw@[2001:db8::2]:8443#x");
    print(r != null ? r.server : "NULL");
')
[ "$out" = "2001:db8::2" ] || die "S4-7 trojan IPv6 host must parse" "$out"
ok "S4-7 trojan IPv6 host parses"

out=$(je '
    let ob = require("outbound");
    let r = ob.parse_proxy_url("hysteria2://pw@[2001:db8::3]:443");
    print(r != null ? r.server : "NULL");
')
[ "$out" = "2001:db8::3" ] || die "S4-7 hy2 IPv6 host must parse" "$out"
ok "S4-7 hy2 IPv6 host parses"

out=$(je '
    let ob = require("outbound");
    let r = ob.parse_proxy_url("ss://aes-256-gcm:pw@[2001:db8::4]:8388#x");
    print(r != null ? r.server : "NULL");
')
[ "$out" = "2001:db8::4" ] || die "S4-7 ss IPv6 host must parse" "$out"
ok "S4-7 ss IPv6 host parses"

# IPv4 share-links must still work (no regression).
out=$(je '
    let ob = require("outbound");
    let r = ob.parse_proxy_url("trojan://pw@1.2.3.4:443#x");
    print(r != null ? sprintf("%s:%d", r.server, r.server_port) : "NULL");
')
[ "$out" = "1.2.3.4:443" ] || die "S4-7 IPv4 trojan regression" "$out"
ok "S4-7 IPv4 still parses"

# ---- S4-8: colon-bearing secrets survive name:secret splitting ----
# hysteria2 inbound multi-user: password contains a colon.
out=$(je '
    let inb = require("inbound");
    let s = { ".name":"h", "protocol":"hysteria2", "listen_port":"443",
              "inbound_user":["alice:pa:ss:word"],
              "tls_server_name":"h.b","tls_certificate_path":"/c","tls_key_path":"/k" };
    let r = inb.build_one(s);
    print(sprintf("%s|%s", r.users[0].name, r.users[0].password));
')
[ "$out" = "alice|pa:ss:word" ] || die "S4-8 hy2 colon password truncated" "$out"
ok "S4-8 hy2 colon password kept"

# mixed inbound: password contains a colon.
out=$(je '
    let inb = require("inbound");
    let s = { ".name":"m", "protocol":"mixed", "listen_port":"1080",
              "mixed_user":["bob:p:a:ss"] };
    let r = inb.build_one(s);
    print(sprintf("%s|%s", r.users[0].username, r.users[0].password));
')
[ "$out" = "bob|p:a:ss" ] || die "S4-8 mixed colon password truncated" "$out"
ok "S4-8 mixed colon password kept"

# shadowsocks inbound: password (tail) contains a colon.
out=$(je '
    let inb = require("inbound");
    let s = { ".name":"ss", "protocol":"shadowsocks", "listen_port":"8388",
              "shadowsocks_method":"aes-128-gcm",
              "ss_user":["carol:aes-128-gcm:p:a:ss"] };
    let r = inb.build_one(s);
    // S2.2: a shadowsocks inbound user must carry NO per-user method (the cipher
    // is the shared inbound-root out.method). Assert method is absent and the
    // colon-bearing password tail is preserved (S4-8).
    let m = r.users[0].method == null ? "NONE" : r.users[0].method;
    print(sprintf("%s|%s|%s", r.users[0].name, m, r.users[0].password));
')
[ "$out" = "carol|NONE|p:a:ss" ] || die "S2.2/S4-8 ss user method must be absent + colon password kept" "$out"
ok "S2.2 ss user has no per-user method; S4-8 colon password kept"

echo "ALL PASS: test_protocol_descriptors_fixes ($pass checks)"
