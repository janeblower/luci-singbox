import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";
import { runUcode } from "../helpers/ucode.ts";

// Port of tests/backend/test_outbound_constructor.sh
const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB = `${WORK}/singbox-ui/root/usr/share/singbox-ui/lib`;
const PARITY_LIB = `${WORK}/tests/parity`;
const GENERATE_UC = `${WORK}/singbox-ui/root/usr/share/singbox-ui/generate.uc`;

describe("outbound_constructor (generate.uc outbounds[] + outbound.build_constructor_for)", () => {
  useGuest();

  const pid = process.pid;
  let tmpDir = "";
  let sandboxDir = "";
  let sandboxConfig = "";

  async function setup() {
    tmpDir = `/tmp/ob_${pid}`;
    sandboxDir = `${tmpDir}/sandbox`;
    sandboxConfig = `${sandboxDir}/singbox-ui.json`;
    await exec(`mkdir -p ${sandboxDir}/subs`);
  }

  async function runGen(cfg: string): Promise<string> {
    await putFile(cfg, `${tmpDir}/singbox-ui`);
    const r = await exec(
      `cd ${WORK} && UCI_CONFIG_DIR=${tmpDir} SINGBOX_TMPDIR=${sandboxDir}/subs SINGBOX_CONFIG=${sandboxConfig} ucode -L ${LIB} ${GENERATE_UC} >/dev/null 2>&1; rc=$?; if [ $rc -eq 0 ]; then cat ${sandboxConfig}; else echo GENFAIL; fi`,
    );
    if (r.stdout.includes("GENFAIL"))
      throw new Error(`generate.uc failed: ${r.stderr}`);
    return r.stdout;
  }

  async function canonNorm(jsonStr: string): Promise<string> {
    const tmpF = `/tmp/ob_cn_${pid}.json`;
    await putFile(jsonStr, tmpF);
    const r = await exec(
      `cd ${WORK} && ucode -L ${LIB} -L ${PARITY_LIB} -e 'let fs=require("fs"); let canon=require("canon").canon; let f=fs.open(ARGV[0],"r"); let j=json(f.read("all")); f.close(); printf("%J", canon(j));' ${tmpF}`,
    );
    await exec(`rm -f ${tmpF}`);
    return r.stdout.trim();
  }

  it("vless with reality + grpc", async () => {
    await setup();
    const raw = await runGen(`
config outbound 'vl'
\toption enabled '1'
\toption type 'vless'
\toption server 'vless.example.com'
\toption server_port '443'
\toption server_uuid 'uuid-aaaa'
\toption vless_flow 'xtls-rprx-vision'
\toption tls_enabled '1'
\toption reality_enabled '1'
\toption tls_server_name 'www.microsoft.com'
\toption utls_enabled '1'
\toption utls_fingerprint 'chrome'
\toption reality_public_key 'PUBKEY'
\toption reality_short_id 'ab12'
\toption transport_type 'grpc'
\toption transport_service_name 'gun'
`);
    expect(raw).toContain('"type": "vless"');
    expect(raw).toContain('"tag": "vl"');
    expect(raw).toContain('"server": "vless.example.com"');
    expect(raw).toContain('"server_port": 443');
    expect(raw).toContain('"uuid": "uuid-aaaa"');
    expect(raw).toContain('"flow": "xtls-rprx-vision"');
    expect(raw).toContain('"public_key": "PUBKEY"');
    expect(raw).toContain('"fingerprint": "chrome"');
    expect(raw).toContain('"service_name": "gun"');
  });

  it("trojan outbound", async () => {
    await setup();
    const raw = await runGen(`
config outbound 'tj'
\toption enabled '1'
\toption type 'trojan'
\toption server 't.example.com'
\toption server_port '443'
\toption server_password 'tj-pw'
\toption tls_enabled '1'
`);
    expect(raw).toContain('"type": "trojan"');
    expect(raw).toContain('"password": "tj-pw"');
    expect(raw).toContain('"enabled": true');
  });

  it("hysteria2 forces tls + obfs", async () => {
    await setup();
    const raw = await runGen(`
config outbound 'hy'
\toption enabled '1'
\toption type 'hysteria2'
\toption server 'h.example.com'
\toption server_port '8443'
\toption server_password 'hy-pw'
\toption obfs_type 'salamander'
\toption obfs_password 'obfs'
\toption up_mbps '50'
\toption down_mbps '100'
`);
    expect(raw).toContain('"type": "hysteria2"');
    expect(raw).toContain('"password": "hy-pw"');
    expect(raw).toContain('"type": "salamander"');
    expect(raw).toContain('"up_mbps": 50');
    expect(raw).toContain('"enabled": true');
  });

  it("shadowsocks outbound", async () => {
    await setup();
    const raw = await runGen(`
config outbound 'ss'
\toption enabled '1'
\toption type 'shadowsocks'
\toption server 's.example.com'
\toption server_port '8388'
\toption shadowsocks_method 'aes-256-gcm'
\toption server_password 'ss-pw'
`);
    expect(raw).toContain('"type": "shadowsocks"');
    expect(raw).toContain('"method": "aes-256-gcm"');
    expect(raw).toContain('"password": "ss-pw"');
  });

  it("extra_json no longer honoured (field deprecated)", async () => {
    await setup();
    const raw = await runGen(`
config outbound 'ex'
\toption enabled '1'
\toption type 'trojan'
\toption server 'e.example.com'
\toption server_port '443'
\toption server_password 'p'
\toption extra_json '{"multiplex":{"enabled":true}}'
`);
    expect(raw).not.toContain('"multiplex":');
  });

  it("section with empty type is skipped (unmigrated)", async () => {
    await setup();
    const raw = await runGen(`
config outbound 'notype'
\toption enabled '1'
`);
    expect(raw).not.toContain('"tag": "notype"');
  });

  it("vless outbound with multiplex + utls", async () => {
    await setup();
    const raw = await runGen(`
config outbound 'vl'
\toption enabled '1'
\toption type 'vless'
\toption server 'a.b'
\toption server_port '443'
\toption server_uuid 'uu'
\toption tls_enabled '1'
\toption tls_server_name 'a.b'
\toption utls_enabled '1'
\toption utls_fingerprint 'chrome'
\toption multiplex_enabled '1'
\toption multiplex_protocol 'smux'
\toption multiplex_max_connections '4'
`);
    expect(raw).toContain('"fingerprint": "chrome"');
    expect(raw).toContain('"protocol": "smux"');
    expect(raw).toContain('"max_connections": 4');
  });

  it("hysteria2 outbound with masquerade", async () => {
    await setup();
    const raw = await runGen(`
config outbound 'hy'
\toption enabled '1'
\toption type 'hysteria2'
\toption server 'h.b'
\toption server_port '8443'
\toption server_password 'p'
\toption up_mbps '100'
\toption down_mbps '50'
\toption masquerade 'https://www.example.com'
`);
    expect(raw).toContain('"masquerade": "https://www.example.com"');
  });

  it("vless outbound with xhttp transport", async () => {
    await setup();
    const raw = await runGen(`
config outbound 'vx'
\toption enabled '1'
\toption type 'vless'
\toption server 'a.b'
\toption server_port '443'
\toption server_uuid 'uu'
\toption transport_type 'xhttp'
\toption transport_path '/x'
\toption transport_xhttp_mode 'stream-up'
`);
    expect(raw).toContain('"type": "xhttp"');
    expect(raw).toContain('"mode": "stream-up"');
  });

  it("hysteria2 outbound with brutal_debug + network restriction", async () => {
    await setup();
    const raw = await runGen(`
config outbound 'hyb'
\toption enabled '1'
\toption type 'hysteria2'
\toption server 'h.b'
\toption server_port '8443'
\toption server_password 'p'
\toption brutal_debug '1'
\toption network 'udp'
`);
    expect(raw).toContain('"brutal_debug": true');
    expect(raw).toContain('"network": "udp"');
  });

  it("hysteria2 outbound rejects unknown network values", async () => {
    await setup();
    const raw = await runGen(`
config outbound 'hybad'
\toption enabled '1'
\toption type 'hysteria2'
\toption server 'h.b'
\toption server_port '8443'
\toption server_password 'p'
\toption network 'sctp'
`);
    expect(raw).not.toContain('"network": "sctp"');
  });

  it("vless outbound with ECH (client-side: config + config_path) + fragment", async () => {
    await setup();
    const raw = await runGen(`
config outbound 'vech'
\toption enabled '1'
\toption type 'vless'
\toption server 'ech.example.com'
\toption server_port '443'
\toption server_uuid 'uu-ech'
\toption tls_enabled '1'
\toption tls_server_name 'ech.example.com'
\toption tls_ech_enabled '1'
\tlist   tls_ech_config '-----BEGIN ECH CONFIG-----'
\tlist   tls_ech_config 'BASE64DATA'
\tlist   tls_ech_config '-----END ECH CONFIG-----'
\toption tls_ech_config_path '/etc/sing-box/ech.pem'
\toption tls_fragment '1'
\toption tls_fragment_fallback_delay '750ms'
\toption tls_record_fragment '1'
`);
    expect(raw).toContain('"ech":');
    expect(raw).toMatch(/"config":\s*\[/);
    expect(raw).toContain('"-----BEGIN ECH CONFIG-----"');
    expect(raw).toContain('"config_path": "/etc/sing-box/ech.pem"');
    expect(raw).toContain('"fragment": true');
    expect(raw).toContain('"fragment_fallback_delay": "750ms"');
    expect(raw).toContain('"record_fragment": true');
    expect(raw).not.toContain("pq_signature_schemes_enabled");
  });

  it("vless outbound without tls_ech / fragment omits all of them", async () => {
    await setup();
    const raw = await runGen(`
config outbound 'vplain'
\toption enabled '1'
\toption type 'vless'
\toption server 'a.b'
\toption server_port '443'
\toption server_uuid 'uu'
\toption tls_enabled '1'
\toption tls_server_name 'a.b'
`);
    expect(raw).not.toContain('"ech":');
    expect(raw).not.toContain('"fragment":');
    expect(raw).not.toContain('"record_fragment":');
  });

  // D1.2: shadowsocks descriptor parity (byte-equal golden)
  it("shadowsocks descriptor parity (D1.2 golden)", async () => {
    const golden =
      '{ "type": "shadowsocks", "tag": "ss1", "server": "example.com", "server_port": 8388, "method": "aes-128-gcm", "password": "pw" }';
    const r = await runUcode(`
let ob = require("outbound");
let s = { ".name":"ss1", "server":"example.com", "server_port":"8388",
          "server_password":"pw", "shadowsocks_method":"aes-128-gcm" };
printf("%J", ob.build_constructor_for(s, "shadowsocks"));
`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe(golden);
  });

  // D1.1: trojan descriptor parity (byte-equal golden)
  it("trojan descriptor parity (D1.1 golden)", async () => {
    const golden =
      '{ "type": "trojan", "tag": "t1", "server": "example.com", "server_port": 443, "password": "pw", "tls": { "enabled": true, "server_name": "example.com" } }';
    const r = await runUcode(`
let ob = require("outbound");
let s = { ".name":"t1", "server":"example.com", "server_port":"443",
          "server_password":"pw", "tls_enabled":"1", "tls_server_name":"example.com" };
printf("%J", ob.build_constructor_for(s, "trojan"));
`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe(golden);
  });

  // D1.3: vless descriptor parity (byte-equal golden)
  it("vless descriptor parity (D1.3 golden)", async () => {
    const golden =
      '{ "type": "vless", "tag": "vl1", "server": "vless.example.com", "server_port": 443, "uuid": "550e8400-e29b-41d4-a716-446655440000", "flow": "xtls-rprx-vision", "tls": { "enabled": true, "server_name": "vless.example.com" } }';
    const r = await runUcode(`
let ob = require("outbound");
let s = { ".name":"vl1", "server":"vless.example.com", "server_port":"443",
          "server_uuid":"550e8400-e29b-41d4-a716-446655440000",
          "vless_flow":"xtls-rprx-vision",
          "tls_enabled":"1", "tls_server_name":"vless.example.com" };
printf("%J", ob.build_constructor_for(s, "vless"));
`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe(golden);
  });

  // D1.5: hysteria2 full descriptor parity (canon-normalized)
  it("hysteria2 descriptor parity: full (D1.5 golden)", async () => {
    const golden =
      '{ "type": "hysteria2", "tag": "hy2full", "server": "hy2.example.com", "server_port": 8443, "password": "secret-pass", "obfs": { "type": "salamander", "password": "obfs-pw" }, "up_mbps": 100, "down_mbps": 50, "masquerade": "https://www.example.com", "brutal_debug": true, "network": "tcp", "tls": { "enabled": true, "server_name": "hy2.example.com" } }';
    const r = await runUcode(`
let ob = require("outbound");
let s = { ".name":"hy2full", "server":"hy2.example.com", "server_port":"8443",
          "server_password":"secret-pass",
          "obfs_type":"salamander", "obfs_password":"obfs-pw",
          "up_mbps":"100", "down_mbps":"50",
          "masquerade":"https://www.example.com",
          "brutal_debug":"1", "network":"tcp",
          "security":"tls", "tls_server_name":"hy2.example.com" };
printf("%J", ob.build_constructor_for(s, "hysteria2"));
`);
    expect(r.exitCode).toBe(0);
    // canon-norm for key-order-agnostic deep-equal
    expect(await canonNorm(r.stdout.trim())).toBe(await canonNorm(golden));
  });

  // D1.5 minimal variant
  it("hysteria2 descriptor parity: minimal (D1.5 golden)", async () => {
    const golden =
      '{ "type": "hysteria2", "tag": "hy2min", "server": "hy2.example.com", "server_port": 8443, "password": "secret-pass", "tls": { "enabled": true, "server_name": "hy2.example.com" } }';
    const r = await runUcode(`
let ob = require("outbound");
let s = { ".name":"hy2min", "server":"hy2.example.com", "server_port":"8443",
          "server_password":"secret-pass",
          "security":"tls", "tls_server_name":"hy2.example.com" };
printf("%J", ob.build_constructor_for(s, "hysteria2"));
`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe(golden);
  });
});
