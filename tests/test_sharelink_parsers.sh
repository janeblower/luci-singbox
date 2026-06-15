#!/bin/sh
# tests/test_sharelink_parsers.sh — share-link parser enhancements (audit
# 9.4 vmess, 9.3 ss SIP002 plugin, 4.3 vless/hy2 #fragment tag, 1.4/4.4
# percent-encoded query keys, 4.2 IPv6 bracket strip).
set -eu
cd "$(dirname "$0")/.."
UCODE_BIN="${UCODE_BIN:-ucode}"
UCODE_LIB_DIR="${UCODE_LIB_DIR:-luci-singbox-ui/root/usr/share/singbox-ui/lib}"
command -v "$UCODE_BIN" >/dev/null 2>&1 || { echo "SKIP test_sharelink_parsers (ucode missing)"; exit 0; }
command -v base64 >/dev/null 2>&1 || { echo "SKIP test_sharelink_parsers (base64 missing)"; exit 0; }

je() { "$UCODE_BIN" -L "$UCODE_LIB_DIR" -e "$1"; }
ok() { echo "  PASS: $1"; }
die() { echo "FAIL: $1 (got: $2)"; exit 1; }

# 9.4: vmess:// (v2rayN base64 JSON) -> sing-box vmess outbound.
VMESS="vmess://$(printf '%s' '{"v":"2","ps":"node1","add":"e.com","port":"443","id":"11111111-1111-1111-1111-111111111111","aid":"0","net":"ws","path":"/p","host":"h.com","tls":"tls","sni":"s.com"}' | base64 -w0)"
out=$(je "
    let r = require('sharelink').parse_proxy_url('$VMESS');
    print(sprintf('%s|%s|%d|%s|%s|%s|%s|%s', r.type, r.server, r.server_port, r.uuid, r.transport.type, r.transport.path, r.tls.server_name, r.tag));
")
[ "$out" = "vmess|e.com|443|11111111-1111-1111-1111-111111111111|ws|/p|s.com|node1" ] \
    || die "9.4 vmess parse" "$out"
ok "9.4 vmess:// parsed (ws+tls), ps -> tag"

# 9.4: malformed vmess base64 -> null (no crash).
out=$(je "let r = require('sharelink').parse_proxy_url('vmess://!!!notbase64'); print(r==null?'NULL':'LEAK');" 2>/dev/null)
[ "$out" = "NULL" ] || die "9.4 bad vmess dropped" "$out"
ok "9.4 malformed vmess dropped"

# 9.3: ss SIP002 ?plugin=name;opts -> plugin + plugin_opts.
SSUSER=$(printf '%s' 'aes-256-gcm:pass' | base64 -w0)
out=$(je "
    let r = require('sharelink').parse_proxy_url('ss://${SSUSER}@1.2.3.4:8388?plugin=obfs-local;obfs=http;obfs-host=x.com#n');
    print(sprintf('%s|%s|%s', r.method, r.plugin, r.plugin_opts));
")
[ "$out" = "aes-256-gcm|obfs-local|obfs=http;obfs-host=x.com" ] || die "9.3 ss plugin" "$out"
ok "9.3 ss SIP002 plugin/plugin_opts extracted"

# 9.3: ss without a plugin must NOT emit plugin keys.
out=$(je "
    let r = require('sharelink').parse_proxy_url('ss://${SSUSER}@1.2.3.4:8388#n');
    print(r.plugin == null ? 'NONE' : 'LEAK');
")
[ "$out" = "NONE" ] || die "9.3 ss no-plugin clean" "$out"
ok "9.3 ss without plugin emits no plugin keys"

# 4.3: vless #fragment becomes the tag (node name).
out=$(je "let r = require('sharelink').parse_proxy_url('vless://11111111-1111-1111-1111-111111111111@h.example:443?security=tls#MyNode'); print(r.tag);")
[ "$out" = "MyNode" ] || die "4.3 vless fragment tag" "$out"
ok "4.3 vless #fragment -> tag"

# 4.3: hy2 #fragment becomes the tag.
out=$(je "let r = require('sharelink').parse_proxy_url('hy2://pw@h.example:443#HyNode'); print(r.tag);")
[ "$out" = "HyNode" ] || die "4.3 hy2 fragment tag" "$out"
ok "4.3 hy2 #fragment -> tag"

# 1.4/4.4: a percent-encoded query KEY (%73ni == sni) is decoded, so the SNI
# parameter is honoured instead of silently dropped.
out=$(je "let r = require('sharelink').parse_proxy_url('vless://11111111-1111-1111-1111-111111111111@h.example:443?security=tls&%73ni=real.sni'); print(r.tls.server_name);")
[ "$out" = "real.sni" ] || die "1.4 percent-encoded query key decoded" "$out"
ok "1.4 percent-encoded query key (%73ni) decoded to sni"

# REALITY: a vless reality link MUST carry flow (xtls-rprx-vision, top-level) and
# short_id (sid -> tls.reality.short_id). Dropping either yields a non-functional
# outbound (the reality handshake is rejected) — this was the root cause of the
# rule-set-update crash: subscription nodes parsed without flow/short_id produced
# a dead proxy, so sing-box could not download remote .srs at startup and FATAL'd.
out=$(je "
    let r = require('sharelink').parse_proxy_url('vless://11111111-1111-1111-1111-111111111111@1.2.3.4:443?type=tcp&security=reality&pbk=PUBKEY&fp=chrome&sid=d38062b9&spx=%2F&flow=xtls-rprx-vision#n');
    print(sprintf('%s|%s|%s|%s', r.flow ?? 'MISSING', r.tls.reality.short_id ?? 'MISSING', r.tls.reality.public_key, r.tls.utls.fingerprint));
")
[ "$out" = "xtls-rprx-vision|d38062b9|PUBKEY|chrome" ] || die "reality flow+short_id" "$out"
ok "vless reality flow + short_id parsed"

# A vless link WITHOUT flow/sid must not emit empty/MISSING keys (clean omission).
out=$(je "
    let r = require('sharelink').parse_proxy_url('vless://11111111-1111-1111-1111-111111111111@1.2.3.4:443?security=reality&pbk=PUBKEY#n');
    print(sprintf('%s|%s', r.flow == null ? 'NONE' : 'LEAK', r.tls.reality.short_id == null ? 'NONE' : 'LEAK'));
")
[ "$out" = "NONE|NONE" ] || die "reality flow/short_id clean omission" "$out"
ok "vless reality without flow/sid omits keys"

# MAP: vless closes prior gaps — alpn (csv) and allowInsecure (bool) now land.
out=$(je "
    let r = require('sharelink').parse_proxy_url('vless://11111111-1111-1111-1111-111111111111@h.ex:443?security=tls&sni=s.com&alpn=h2,http%2F1.1&allowInsecure=1&fp=chrome#n');
    print(sprintf('%s|%d|%s|%s', r.tls.server_name, length(r.tls.alpn), r.tls.insecure===true?'T':'?', r.tls.utls.fingerprint));
")
[ "$out" = "s.com|2|T|chrome" ] || die "vless alpn/allowInsecure/fp" "$out"
ok "vless alpn+allowInsecure+fp mapped via SPEC"

# MAP: vless encryption/spx/mode/headerType are declared unsupported -> absent.
out=$(je "
    let r = require('sharelink').parse_proxy_url('vless://11111111-1111-1111-1111-111111111111@h.ex:443?security=tls&encryption=none&mode=gun&headerType=http&spx=%2F#n');
    print(sprintf('%s|%s|%s|%s', r.encryption==null?'OMIT':'LEAK', r.mode==null?'OMIT':'LEAK', r.headerType==null?'OMIT':'LEAK', r.spx==null?'OMIT':'LEAK'));
")
[ "$out" = "OMIT|OMIT|OMIT|OMIT" ] || die "vless unsupported absent" "$out"
ok "vless encryption/mode/headerType/spx left unmapped (declared)"

# MAP: a plain vless (no security=) produces NO tls block.
out=$(je "
    let r = require('sharelink').parse_proxy_url('vless://11111111-1111-1111-1111-111111111111@h.ex:443?type=ws&path=%2Fw#n');
    print(r.tls==null ? 'NOTLS' : 'LEAK');
")
[ "$out" = "NOTLS" ] || die "vless plain no tls" "$out"
ok "vless without security emits no tls block"

# MAP: security=reality but MISSING pbk must NOT emit a reality block
# (a reality block without public_key FATALs sing-box at config load).
out=$(je "
    let r = require('sharelink').parse_proxy_url('vless://11111111-1111-1111-1111-111111111111@h.ex:443?security=reality&sid=ab#n');
    print(sprintf('%s|%s', r.tls.enabled===true?'TLS':'?', r.tls.reality==null?'NOREALITY':'LEAK'));
")
[ "$out" = "TLS|NOREALITY" ] || die "vless reality without pbk omits reality" "$out"
ok "vless reality missing pbk omits reality block (no FATAL config)"

# MAP: trojan — sni/peer alias (sni wins), alpn csv, allowInsecure bool, transport ws.
out=$(je "
    let r = require('sharelink').parse_proxy_url('trojan://pw@h.ex:443?peer=p.com&sni=s.com&alpn=h2&allowInsecure=1&type=ws&path=%2Fw&host=ws.com#n');
    print(sprintf('%s|%d|%s|%s|%s|%s', r.tls.server_name, length(r.tls.alpn), r.tls.insecure===true?'T':'?', r.transport.type, r.transport.path, r.transport.headers.Host));
")
[ "$out" = "s.com|1|T|ws|/w|ws.com" ] || die "trojan map" "$out"
ok "trojan sni/peer+alpn+insecure+ws via SPEC"

# MAP: hysteria2 closes gaps — alpn (csv) now lands; insecure bool; obfs preserved.
out=$(je "
    let r = require('sharelink').parse_proxy_url('hy2://pw@h.ex:443?sni=s.com&insecure=1&alpn=h3&obfs=salamander&obfs-password=op#n');
    print(sprintf('%s|%s|%d|%s|%s', r.tls.server_name, r.tls.insecure===true?'T':'?', length(r.tls.alpn), r.obfs.type, r.obfs.password));
")
[ "$out" = "s.com|T|1|salamander|op" ] || die "hy2 alpn/insecure/obfs" "$out"
ok "hysteria2 alpn+insecure+obfs via SPEC"

# MAP: hysteria2 pinSHA256 is declared unsupported -> not emitted.
out=$(je "
    let r = require('sharelink').parse_proxy_url('hy2://pw@h.ex:443?sni=s.com&pinSHA256=abc#n');
    print(r.tls.pinSHA256==null && r.fingerprint==null ? 'OMIT' : 'LEAK');
")
[ "$out" = "OMIT" ] || die "hy2 pinSHA256 unsupported" "$out"
ok "hysteria2 pinSHA256/mport declared unsupported"

# MAP: vmess alpn/fp now land on the tls block (closing a prior gap).
VMESS2="vmess://$(printf '%s' '{"v":"2","ps":"n","add":"e.com","port":"443","id":"11111111-1111-1111-1111-111111111111","aid":"0","net":"tcp","tls":"tls","sni":"s.com","alpn":"h2,http/1.1","fp":"chrome"}' | base64 -w0)"
out=$(je "
    let r = require('sharelink').parse_proxy_url('$VMESS2');
    print(sprintf('%s|%d|%s', r.tls.server_name, length(r.tls.alpn), r.tls.utls.fingerprint));
")
[ "$out" = "s.com|2|chrome" ] || die "vmess alpn/fp" "$out"
ok "vmess alpn+fp mapped via SPEC"

# NEW: tuic://uuid:password@host:port?params  -> sing-box tuic outbound.
out=$(je "
    let r = require('sharelink').parse_proxy_url('tuic://11111111-1111-1111-1111-111111111111:secret@h.ex:443?congestion_control=bbr&udp_relay_mode=native&sni=s.com&alpn=h3&allow_insecure=1#TU');
    print(sprintf('%s|%s|%s|%s|%s|%d|%s|%s', r.type, r.uuid, r.password, r.congestion_control, r.udp_relay_mode, length(r.tls.alpn), r.tls.server_name, r.tls.insecure===true?'T':'?'));
")
[ "$out" = "tuic|11111111-1111-1111-1111-111111111111|secret|bbr|native|1|s.com|T" ] || die "tuic parse" "$out"
ok "tuic:// parsed (uuid:password + congestion/udp_relay/tls)"

# NEW: hysteria:// (v1) -> sing-box hysteria outbound (auth_str/up_mbps/down_mbps/tls).
out=$(je "
    let r = require('sharelink').parse_proxy_url('hysteria://h.ex:443?auth=tok&peer=s.com&insecure=1&alpn=h3&upmbps=50&downmbps=100&obfs=xplus#H1');
    print(sprintf('%s|%s|%s|%d|%d|%s|%s', r.type, r.auth_str, r.tls.server_name, r.up_mbps, r.down_mbps, r.obfs, r.tls.insecure===true?'T':'?'));
")
[ "$out" = "hysteria|tok|s.com|50|100|xplus|T" ] || die "hysteria v1 parse" "$out"
ok "hysteria:// (v1) parsed (auth/up/down/peer/obfs)"

# NEW: anytls://password@host:port?params -> sing-box anytls outbound.
out=$(je "
    let r = require('sharelink').parse_proxy_url('anytls://mypass@h.ex:443?sni=s.com&insecure=1&alpn=h2#AT');
    print(sprintf('%s|%s|%s|%d|%s', r.type, r.password, r.tls.server_name, length(r.tls.alpn), r.tls.insecure===true?'T':'?'));
")
[ "$out" = "anytls|mypass|s.com|1|T" ] || die "anytls parse" "$out"
ok "anytls:// parsed (password + tls/sni/alpn/insecure)"

# NEW: socks5://base64(user:pass)@host:port -> sing-box socks outbound (version 5).
SOCKSUSER=$(printf '%s' 'alice:s3cret' | base64 -w0)
out=$(je "
    let r = require('sharelink').parse_proxy_url('socks5://${SOCKSUSER}@h.ex:1080#SK');
    print(sprintf('%s|%s|%s|%s|%d', r.type, r.version, r.username, r.password, r.server_port));
")
[ "$out" = "socks|5|alice|s3cret|1080" ] || die "socks5 parse" "$out"
ok "socks5:// parsed (base64 user:pass + version 5)"

# NEW: socks:// with plain userinfo (no base64) also works; udp param declared unsupported.
out=$(je "
    let r = require('sharelink').parse_proxy_url('socks://bob:pw@h.ex:1080?udp=1#SK2');
    print(sprintf('%s|%s|%s|%s', r.username, r.password, r.version, r.udp==null?'OMIT':'LEAK'));
")
[ "$out" = "bob|pw|5|OMIT" ] || die "socks plain parse" "$out"
ok "socks:// plain userinfo; udp declared unsupported"

# NEW: socks user-only userinfo that is coincidentally valid base64 must stay literal.
out=$(je "
    let r = require('sharelink').parse_proxy_url('socks://justuser@h.ex:1080#n');
    print(sprintf('%s|%s', r.username, r.password==null?'NOPASS':'LEAK'));
")
[ "$out" = "justuser|NOPASS" ] || die "socks user-only literal" "$out"
ok "socks:// user-only userinfo kept literal (not mis-decoded as base64)"

echo "OK"
