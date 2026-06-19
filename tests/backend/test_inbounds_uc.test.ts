import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";
import { runUcode } from "../helpers/ucode.ts";

// Port of tests/backend/test_inbounds_uc.sh
const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB = `${WORK}/singbox-ui/root/usr/share/singbox-ui/lib`;
const PARITY_LIB = `${WORK}/tests/parity`;
const GENERATE_UC = `${WORK}/singbox-ui/root/usr/share/singbox-ui/generate.uc`;

describe("inbounds_uc (generate.uc inbounds[] + inbound.build_one)", () => {
  useGuest();

  const pid = process.pid;
  let genBase = "";
  let sandboxDir = "";
  let sandboxConfig = "";

  async function setup() {
    genBase = `/tmp/inb_${pid}`;
    sandboxDir = `${genBase}/sandbox`;
    sandboxConfig = `${sandboxDir}/singbox-ui.json`;
    await exec(`mkdir -p ${sandboxDir}/subs`);
  }

  async function runGen(cfg: string): Promise<string> {
    await putFile(cfg, `${genBase}/singbox-ui`);
    const r = await exec(
      `cd ${WORK} && UCI_CONFIG_DIR=${genBase} SINGBOX_TMPDIR=${sandboxDir}/subs SINGBOX_CONFIG=${sandboxConfig} ucode -L ${LIB} ${GENERATE_UC} >/dev/null 2>&1; rc=$?; if [ $rc -eq 0 ]; then cat ${sandboxConfig}; else echo GENFAIL; fi`,
    );
    if (r.stdout.includes("GENFAIL"))
      throw new Error(`generate.uc failed: ${r.stderr}`);
    return r.stdout;
  }

  // Canon-normalize JSON for order-agnostic deep-equal comparison
  async function canonNorm(jsonStr: string): Promise<string> {
    const tmpF = `/tmp/inb_cn_${pid}.json`;
    await putFile(jsonStr, tmpF);
    const r = await exec(
      `cd ${WORK} && ucode -L ${LIB} -L ${PARITY_LIB} -e 'let fs=require("fs"); let canon=require("canon").canon; let f=fs.open(ARGV[0],"r"); let j=json(f.read("all")); f.close(); printf("%J", canon(j));' ${tmpF}`,
    );
    await exec(`rm -f ${tmpF}`);
    return r.stdout.trim();
  }

  it("tproxy inbound from inbound section", async () => {
    await setup();
    const raw = await runGen(`
config inbound 'tin'
\toption enabled '1'
\toption mode 'constructor'
\toption protocol 'tproxy'
\toption listen '::'
\toption listen_port '7893'
\tlist interface 'br-lan'
\toption nft_rules '1'
\toption tcp_fast_open '1'
`);
    expect(raw).toContain('"type": "tproxy"');
    expect(raw).toContain('"tag": "tin"');
    expect(raw).toContain('"listen": "::"');
    expect(raw).toContain('"listen_port": 7893');
    expect(raw).toContain('"tcp_fast_open": true');
  });

  it("disabled inbound is skipped", async () => {
    await setup();
    const raw = await runGen(`
config inbound 'off'
\toption enabled '0'
\toption protocol 'tproxy'
\toption listen_port '7893'
`);
    expect(raw).not.toContain('"tag": "off"');
  });

  it("listen-based inbound without port is skipped", async () => {
    await setup();
    const raw = await runGen(`
config inbound 'noport'
\toption enabled '1'
\toption protocol 'shadowsocks'
\toption server_password 'x'
`);
    expect(raw).not.toContain('"tag": "noport"');
  });

  it("shadowsocks inbound", async () => {
    await setup();
    const raw = await runGen(`
config inbound 'ss'
\toption enabled '1'
\toption protocol 'shadowsocks'
\toption listen_port '8388'
\toption shadowsocks_method 'aes-256-gcm'
\toption server_password 'p@ss'
`);
    expect(raw).toContain('"type": "shadowsocks"');
    expect(raw).toContain('"method": "aes-256-gcm"');
    expect(raw).toContain('"password": "p@ss"');
  });

  it("vless inbound with reality + ws transport", async () => {
    await setup();
    const raw = await runGen(`
config inbound 'vl'
\toption enabled '1'
\toption protocol 'vless'
\toption listen_port '443'
\toption server_uuid 'uuid-1111'
\toption vless_flow 'xtls-rprx-vision'
\toption tls_enabled '1'
\toption reality_enabled '1'
\toption reality_private_key 'PRIVKEY'
\toption reality_short_id 'ab12'
\toption reality_handshake_server 'www.example.com'
\toption reality_handshake_server_port '443'
\toption transport_type 'ws'
\toption transport_path '/ray'
\toption transport_host 'cdn.example.com'
`);
    expect(raw).toContain('"type": "vless"');
    expect(raw).toContain('"uuid": "uuid-1111"');
    expect(raw).toContain('"flow": "xtls-rprx-vision"');
    expect(raw).toContain('"reality":');
    expect(raw).toContain('"private_key": "PRIVKEY"');
    // sing-box 1.12: short_id is a single string, not an array
    expect(raw).toContain('"short_id": "ab12"');
    expect(raw).not.toMatch(/"short_id":\s*\[/);
    expect(raw).toContain('"server": "www.example.com"');
    expect(raw).toContain('"type": "ws"');
    expect(raw).toContain('"path": "/ray"');
  });

  it("trojan inbound", async () => {
    await setup();
    const raw = await runGen(`
config inbound 'tj'
\toption enabled '1'
\toption protocol 'trojan'
\toption listen_port '443'
\toption server_password 'trojan-pw'
\toption tls_enabled '1'
\toption tls_certificate_path '/c.pem'
\toption tls_key_path '/k.pem'
`);
    expect(raw).toContain('"type": "trojan"');
    expect(raw).toContain('"password": "trojan-pw"');
  });

  it("hysteria2 inbound forces tls + obfs", async () => {
    await setup();
    const raw = await runGen(`
config inbound 'hy'
\toption enabled '1'
\toption protocol 'hysteria2'
\toption listen_port '8443'
\toption server_password 'hy-pw'
\toption obfs_type 'salamander'
\toption obfs_password 'obfs-pw'
\toption up_mbps '100'
\toption down_mbps '200'
\toption tls_certificate_path '/c.pem'
\toption tls_key_path '/k.pem'
`);
    expect(raw).toContain('"type": "hysteria2"');
    expect(raw).toContain('"password": "hy-pw"');
    expect(raw).toContain('"type": "salamander"');
    expect(raw).toContain('"password": "obfs-pw"');
    expect(raw).toContain('"up_mbps": 100');
    expect(raw).toContain('"enabled": true');
  });

  it("extra_json is no longer honoured for inbounds (field deprecated)", async () => {
    await setup();
    const raw = await runGen(`
config inbound 'tp'
\toption enabled '1'
\toption protocol 'tproxy'
\toption listen_port '7893'
\toption extra_json '{"sniff":true,"sniff_override_destination":true}'
`);
    expect(raw).not.toContain('"sniff": true');
  });

  it("vless inbound with http transport (multi-host list + tls alpn list)", async () => {
    await setup();
    const raw = await runGen(`
config inbound 'http_in'
\toption enabled '1'
\toption protocol 'vless'
\toption listen_port '8445'
\toption server_uuid 'uuid-9999'
\toption transport_type 'http'
\toption transport_path '/api'
\tlist   transport_hosts 'a.example.com'
\tlist   transport_hosts 'b.example.com'
\toption tls_enabled '1'
\toption tls_certificate_path '/c.pem'
\toption tls_key_path '/k.pem'
\tlist   tls_alpn 'h2'
\tlist   tls_alpn 'http/1.1'
`);
    expect(raw).toContain('"type": "http"');
    expect(raw).toContain('"a.example.com"');
    expect(raw).toContain('"b.example.com"');
    expect(raw).toContain('"h2"');
    expect(raw).toContain('"http/1.1"');
  });

  it("direct (DNS) inbound on 127.0.0.53:53", async () => {
    await setup();
    const raw = await runGen(`
config inbound 'dns_in'
\toption enabled '1'
\toption protocol 'direct'
\toption listen '127.0.0.53'
\toption listen_port '53'
\toption network 'udp'
`);
    expect(raw).toContain('"type": "direct"');
    expect(raw).toContain('"tag": "dns_in"');
    expect(raw).toContain('"listen": "127.0.0.53"');
    expect(raw).toContain('"listen_port": 53');
    expect(raw).toContain('"network": "udp"');
  });

  it("mode='json' is no longer recognised; section skipped", async () => {
    await setup();
    const raw = await runGen(`
config inbound 'raw'
\toption enabled '1'
\toption mode 'json'
\toption inbound_json '{"type":"mixed","listen":"127.0.0.1","listen_port":2080}'
`);
    expect(raw).not.toContain('"tag": "raw"');
  });

  it("mode='constructor' is treated as no-op (protocol-first works)", async () => {
    await setup();
    const raw = await runGen(`
config inbound 'tin'
\toption enabled '1'
\toption mode 'constructor'
\toption protocol 'tproxy'
\toption listen_port '7893'
`);
    expect(raw).toContain('"tag": "tin"');
  });

  it("vless inbound with multiplex + xhttp transport", async () => {
    await setup();
    const raw = await runGen(`
config inbound 'vl2'
\toption enabled '1'
\toption protocol 'vless'
\toption listen_port '443'
\toption server_uuid 'uuid-3'
\toption transport_type 'xhttp'
\toption transport_path '/x'
\toption transport_xhttp_mode 'stream-up'
\toption multiplex_enabled '1'
\toption multiplex_protocol 'smux'
\toption multiplex_max_connections '4'
`);
    expect(raw).toContain('"multiplex":');
    expect(raw).toContain('"protocol": "smux"');
    expect(raw).toContain('"max_connections": 4');
    expect(raw).toContain('"type": "xhttp"');
    expect(raw).toContain('"mode": "stream-up"');
  });

  it("hysteria2 inbound with masquerade + utls", async () => {
    await setup();
    const raw = await runGen(`
config inbound 'hy'
\toption enabled '1'
\toption protocol 'hysteria2'
\toption listen_port '8443'
\toption server_password 'p'
\toption up_mbps '100'
\toption down_mbps '50'
\toption masquerade 'https://www.example.com'
\toption tls_server_name 'hy.example.com'
\toption tls_certificate_path '/etc/ssl/cert.pem'
\toption tls_key_path '/etc/ssl/key.pem'
`);
    expect(raw).toContain('"masquerade": "https://www.example.com"');
  });

  it("hysteria2 inbound with brutal_debug + ignore_client_bandwidth", async () => {
    await setup();
    const raw = await runGen(`
config inbound 'hy2lim'
\toption enabled '1'
\toption protocol 'hysteria2'
\toption listen_port '8443'
\toption server_password 'pw'
\toption up_mbps '500'
\toption down_mbps '500'
\toption brutal_debug '1'
\toption ignore_client_bandwidth '1'
`);
    expect(raw).toContain('"up_mbps": 500');
    expect(raw).toContain('"down_mbps": 500');
    expect(raw).toContain('"brutal_debug": true');
    expect(raw).toContain('"ignore_client_bandwidth": true');
  });

  it("hysteria2 inbound without debug/ignore flags omits both", async () => {
    await setup();
    const raw = await runGen(`
config inbound 'hy2def'
\toption enabled '1'
\toption protocol 'hysteria2'
\toption listen_port '8443'
\toption server_password 'pw'
`);
    expect(raw).not.toContain('"brutal_debug":');
    expect(raw).not.toContain('"ignore_client_bandwidth":');
  });

  it("vless inbound with ECH (server-side: key + key_path)", async () => {
    await setup();
    const raw = await runGen(`
config inbound 'vech'
\toption enabled '1'
\toption protocol 'vless'
\toption listen_port '4443'
\toption server_uuid 'uuid-ech'
\toption tls_enabled '1'
\toption tls_server_name 'ech.example.com'
\toption tls_certificate_path '/etc/ssl/cert.pem'
\toption tls_key_path '/etc/ssl/key.pem'
\toption tls_ech_enabled '1'
\tlist   tls_ech_key '-----BEGIN ECH KEY-----'
\tlist   tls_ech_key 'AAAA'
\tlist   tls_ech_key '-----END ECH KEY-----'
\toption tls_ech_key_path '/etc/ssl/ech.key'
`);
    expect(raw).toContain('"ech":');
    expect(raw).toContain('"enabled": true');
    expect(raw).toMatch(/"key":\s*\[/);
    expect(raw).toContain('"-----BEGIN ECH KEY-----"');
    expect(raw).toContain('"key_path": "/etc/ssl/ech.key"');
    // Deprecated in 1.12 / removed in 1.13 — never emitted
    expect(raw).not.toContain("pq_signature_schemes_enabled");
  });

  it("vless inbound without tls_ech omits the ech block", async () => {
    await setup();
    const raw = await runGen(`
config inbound 'noech'
\toption enabled '1'
\toption protocol 'vless'
\toption listen_port '4444'
\toption server_uuid 'uuid-noech'
\toption tls_enabled '1'
\toption tls_server_name 'plain.example.com'
`);
    expect(raw).not.toContain('"ech":');
  });

  it("shadowsocks inbound multi-user + network + multiplex", async () => {
    await setup();
    const raw = await runGen(`
config inbound 'ss_multi'
\toption enabled '1'
\toption protocol 'shadowsocks'
\toption listen_port '8388'
\toption shadowsocks_method '2022-blake3-aes-128-gcm'
\toption server_password 'should-be-ignored'
\tlist   ss_user 'alice:2022-blake3-aes-128-gcm:pw1'
\tlist   ss_user 'bob:2022-blake3-aes-128-gcm:pw2'
\toption network 'tcp'
\toption multiplex_enabled '1'
\toption multiplex_protocol 'smux'
`);
    expect(raw).toContain('"type": "shadowsocks"');
    expect(raw).toContain('"method": "2022-blake3-aes-128-gcm"');
    expect(raw).toContain('"name": "alice"');
    expect(raw).toContain('"password": "pw1"');
    expect(raw).toContain('"name": "bob"');
    expect(raw).toContain('"password": "pw2"');
    expect(raw).toContain('"network": "tcp"');
    expect(raw).toContain('"protocol": "smux"');
    // Top-level password dropped when users[] present
    expect(raw).not.toContain('"password": "should-be-ignored"');
  });

  it("shadowsocks inbound single-user (no ss_user list)", async () => {
    await setup();
    const raw = await runGen(`
config inbound 'ss_single'
\toption enabled '1'
\toption protocol 'shadowsocks'
\toption listen_port '8388'
\toption shadowsocks_method 'aes-128-gcm'
\toption server_password 'single-pw'
`);
    expect(raw).toContain('"type": "shadowsocks"');
    expect(raw).toContain('"password": "single-pw"');
    expect(raw).not.toContain('"users":');
    expect(raw).not.toContain('"network":');
    expect(raw).not.toContain('"multiplex":');
  });

  it("shadowsocks inbound malformed ss_user entries are skipped", async () => {
    await setup();
    const raw = await runGen(`
config inbound 'ss_bad'
\toption enabled '1'
\toption protocol 'shadowsocks'
\toption listen_port '8388'
\toption shadowsocks_method 'aes-128-gcm'
\tlist   ss_user 'no-colon-here'
\tlist   ss_user 'only:two-parts'
\tlist   ss_user 'good:aes-128-gcm:gp'
`);
    expect(raw).toContain('"name": "good"');
    expect(raw).toContain('"password": "gp"');
    expect(raw).not.toContain('"name": "no-colon-here"');
    expect(raw).not.toContain('"name": "only"');
  });

  it("vless inbound multi-user with per-user flow", async () => {
    await setup();
    const raw = await runGen(`
config inbound 'vl_multi'
\toption enabled '1'
\toption protocol 'vless'
\toption listen_port '4443'
\toption server_uuid 'section-uuid'
\toption vless_flow 'xtls-rprx-vision'
\tlist   inbound_user 'alice:uuid-aaa:xtls-rprx-vision'
\tlist   inbound_user 'bob:uuid-bbb:none'
\tlist   inbound_user 'carol:uuid-ccc'
`);
    expect(raw).toContain('"flow": "xtls-rprx-vision"');
    expect(raw).toContain('"uuid": "uuid-aaa"');
    expect(raw).toContain('"uuid": "uuid-bbb"');
    expect(raw).toContain('"uuid": "uuid-ccc"');
    expect(raw).not.toContain('"uuid": "section-uuid"');
  });

  // D1.5.3: shadowsocks inbound descriptor parity (golden)
  it("shadowsocks inbound descriptor parity: multi-user (D1.5.3 golden)", async () => {
    const golden =
      '{ "type": "shadowsocks", "tag": "ss_in1", "listen": "::", "listen_port": 8388, "method": "2022-blake3-aes-128-gcm", "network": "tcp", "users": [ { "name": "alice", "password": "pwA" }, { "name": "bob", "password": "pwB" } ] }';
    const r = await runUcode(`
let inb = require("inbound");
let s = { ".name":"ss_in1", "protocol":"shadowsocks", "listen":"::", "listen_port":"8388",
          "shadowsocks_method":"2022-blake3-aes-128-gcm",
          "ss_user":["alice:2022-blake3-aes-128-gcm:pwA","bob:2022-blake3-aes-128-gcm:pwB"], "network":"tcp" };
printf("%J", inb.build_one(s));
`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe(golden);
  });

  it("shadowsocks inbound descriptor parity: single-user fallback (D1.5.3 golden)", async () => {
    const golden =
      '{ "type": "shadowsocks", "tag": "ss_in2", "listen": "::", "listen_port": 8388, "method": "aes-128-gcm", "password": "pw" }';
    const r = await runUcode(`
let inb = require("inbound");
let s = { ".name":"ss_in2", "protocol":"shadowsocks", "listen_port":"8388",
          "shadowsocks_method":"aes-128-gcm", "server_password":"pw" };
printf("%J", inb.build_one(s));
`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe(golden);
  });

  // D1.5.2: trojan inbound descriptor parity (golden)
  it("trojan inbound descriptor parity (D1.5.2 golden)", async () => {
    const golden =
      '{ "type": "trojan", "tag": "in_t1", "listen": "::", "listen_port": 443, "users": [ { "name": "in_t1", "password": "pw" } ], "tls": { "enabled": true, "certificate_path": "/etc/ssl/c.pem", "key_path": "/etc/ssl/k.pem" } }';
    const r = await runUcode(`
let inb = require("inbound");
let s = { ".name":"in_t1", "protocol":"trojan", "listen":"::", "listen_port":"443",
          "server_password":"pw", "tls_enabled":"1",
          "tls_certificate_path":"/etc/ssl/c.pem", "tls_key_path":"/etc/ssl/k.pem" };
printf("%J", inb.build_one(s));
`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe(golden);
  });

  // D1.5.4: vless inbound descriptor parity (golden) multi-user
  it("vless inbound descriptor parity: multi-user (D1.5.4 golden)", async () => {
    const golden =
      '{ "type": "vless", "tag": "v_in1", "listen": "::", "listen_port": 443, "users": [ { "name": "alice", "uuid": "11111111-1111-1111-1111-111111111111" }, { "name": "bob", "uuid": "22222222-2222-2222-2222-222222222222", "flow": "xtls-rprx-vision" } ], "tls": { "enabled": true, "certificate_path": "/etc/ssl/cert.pem", "key_path": "/etc/ssl/key.pem" } }';
    const r = await runUcode(`
let inb = require("inbound");
let s = { ".name":"v_in1", "protocol":"vless", "listen":"::", "listen_port":"443",
          "inbound_user":["alice:11111111-1111-1111-1111-111111111111",
                          "bob:22222222-2222-2222-2222-222222222222:xtls-rprx-vision"],
          "tls_enabled":"1",
          "tls_certificate_path":"/etc/ssl/cert.pem", "tls_key_path":"/etc/ssl/key.pem" };
printf("%J", inb.build_one(s));
`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe(golden);
  });

  it("vless inbound descriptor parity: single-user (D1.5.4 golden)", async () => {
    const golden =
      '{ "type": "vless", "tag": "v_in2", "listen": "::", "listen_port": 443, "users": [ { "name": "v_in2", "uuid": "33333333-3333-3333-3333-333333333333", "flow": "xtls-rprx-vision" } ], "tls": { "enabled": true, "certificate_path": "/etc/ssl/cert.pem", "key_path": "/etc/ssl/key.pem" } }';
    const r = await runUcode(`
let inb = require("inbound");
let s = { ".name":"v_in2", "protocol":"vless", "listen":"::", "listen_port":"443",
          "server_uuid":"33333333-3333-3333-3333-333333333333",
          "vless_flow":"xtls-rprx-vision",
          "tls_enabled":"1",
          "tls_certificate_path":"/etc/ssl/cert.pem", "tls_key_path":"/etc/ssl/key.pem" };
printf("%J", inb.build_one(s));
`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe(golden);
  });

  // D1.5.6: hysteria2 inbound descriptor parity full — canon_norm compare
  it("hysteria2 inbound descriptor parity: full (D1.5.6 golden)", async () => {
    const golden =
      '{ "type": "hysteria2", "tag": "h2_in1", "listen": "::", "listen_port": 443, "users": [ { "name": "h2_in1", "password": "pw" } ], "obfs": { "type": "salamander", "password": "obfspw" }, "up_mbps": 100, "down_mbps": 200, "masquerade": "https://example.com", "brutal_debug": true, "ignore_client_bandwidth": true, "tls": { "enabled": true, "server_name": "h2.example.com", "certificate_path": "/etc/ssl/c.pem", "key_path": "/etc/ssl/k.pem" } }';
    const r = await runUcode(`
let inb = require("inbound");
let s = { ".name":"h2_in1", "protocol":"hysteria2", "listen_port":"443",
          "server_password":"pw",
          "obfs_type":"salamander", "obfs_password":"obfspw",
          "up_mbps":"100", "down_mbps":"200",
          "masquerade":"https://example.com",
          "brutal_debug":"1", "ignore_client_bandwidth":"1",
          "tls_server_name":"h2.example.com",
          "tls_certificate_path":"/etc/ssl/c.pem", "tls_key_path":"/etc/ssl/k.pem" };
printf("%J", inb.build_one(s));
`);
    expect(r.exitCode).toBe(0);
    // Use canonical key-sorted comparison for order-agnostic deep-equal
    expect(await canonNorm(r.stdout.trim())).toBe(await canonNorm(golden));
  });

  it("hysteria2 inbound descriptor parity: minimal (D1.5.6 golden)", async () => {
    const golden =
      '{ "type": "hysteria2", "tag": "h2_in2", "listen": "::", "listen_port": 443, "users": [ { "name": "h2_in2", "password": "pw" } ], "tls": { "enabled": true, "server_name": "h2.example.com", "certificate_path": "/etc/ssl/c.pem", "key_path": "/etc/ssl/k.pem" } }';
    const r = await runUcode(`
let inb = require("inbound");
let s = { ".name":"h2_in2", "protocol":"hysteria2", "listen_port":"443",
          "server_password":"pw",
          "tls_server_name":"h2.example.com",
          "tls_certificate_path":"/etc/ssl/c.pem", "tls_key_path":"/etc/ssl/k.pem" };
printf("%J", inb.build_one(s));
`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe(golden);
  });
});
