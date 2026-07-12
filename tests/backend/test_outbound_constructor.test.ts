import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";
import { runUcode } from "../helpers/ucode.ts";

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB = `${WORK}/singbox-ui/root/usr/share/singbox-ui/lib`;
const PARITY_LIB = `${WORK}/tests/parity`;
const GENERATE_UC = `${WORK}/singbox-ui/root/usr/share/singbox-ui/generate.uc`;

// Shape of a generated config outbound / doc, enough to type the JSON.parse
// results below so tsc's strict noImplicitAny is satisfied without `any`.
type Ob = {
  tag?: string;
  type?: string;
  server?: string;
  outbounds?: string[];
  url?: string;
  detour?: string;
};
type Doc = { outbounds: Ob[] };

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

  // Like runGen but also returns generate.uc's stderr (warnings). The C-1 gate
  // needs it: the pre-existing GEN-1/BLD-7 dangling-member prune rescues the
  // final config either way, so its warning is the only observable proof that
  // the buggy static resolve emitted a dangling group reference.
  async function runGenErr(cfg: string): Promise<{ doc: Doc; stderr: string }> {
    await putFile(cfg, `${tmpDir}/singbox-ui`);
    const r = await exec(
      `cd ${WORK} && UCI_CONFIG_DIR=${tmpDir} SINGBOX_TMPDIR=${sandboxDir}/subs SINGBOX_CONFIG=${sandboxConfig} ucode -L ${LIB} ${GENERATE_UC} >/dev/null 2>${tmpDir}/gen_err.txt; rc=$?; if [ $rc -eq 0 ]; then cat ${sandboxConfig}; else echo GENFAIL; fi; cat ${tmpDir}/gen_err.txt >&2`,
    );
    if (r.stdout.includes("GENFAIL"))
      throw new Error(`generate.uc failed: ${r.stderr}`);
    return { doc: JSON.parse(r.stdout) as Doc, stderr: r.stderr };
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

  // seed(subName, lines) — write sub_<subName>.txt lines (node/group records)
  // under the sandbox subs/ dir, the way subscription.uc's fetch would.
  async function seed(subName: string, lines: string[]): Promise<void> {
    const body = lines.join("\n").replace(/'/g, "'\\''");
    await exec(
      `printf '%s\\n' '${body}' > ${sandboxDir}/subs/sub_${subName}.txt`,
    );
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

  it("subscription detour to a non-subscription tag is dropped (no leak)", async () => {
    await setup();
    // one node record with a provider detour pointing at the builtin direct
    const line = JSON.stringify({
      o: {
        type: "vless",
        server: "1.2.3.4",
        server_port: 443,
        uuid: "11111111-1111-1111-1111-111111111111",
      },
      n: "Node A",
      l: null,
      d: "direct",
    });
    await exec(
      `printf '%s\\n' '${line.replace(/'/g, "'\\''")}' > ${sandboxDir}/subs/sub_s.txt`,
    );
    const cfg = await runGen(`
config outbound 's'
\toption enabled '1'
\toption type 'subscription'
\toption sub_url 'https://x/y'
\toption sub_multi '1'
`);
    const doc = JSON.parse(cfg) as Doc;
    const node = doc.outbounds.find((o) => (o.tag || "").startsWith("s__"));
    expect(node).toBeTruthy();
    expect(node?.detour).toBeUndefined();
  });

  it("self-referential subscription detour is dropped (self-guard, no runtime loop)", async () => {
    await setup();
    // One node whose provider detour names ITSELF: name_to_tag['X'] resolves
    // back to this node's own tag, so target === the node's own tag. Without the
    // self-guard the outbound emits detour === its own tag — sing-box check
    // passes, then the dial path loops/hangs at runtime whenever it is used.
    const line = JSON.stringify({
      o: {
        type: "vless",
        server: "1.2.3.4",
        server_port: 443,
        uuid: "11111111-1111-1111-1111-111111111111",
      },
      n: "X",
      l: null,
      d: "X",
    });
    await seed("s", [line]);
    const cfg = await runGen(`
config outbound 's'
\toption enabled '1'
\toption type 'subscription'
\toption sub_url 'https://x/y'
\toption sub_multi '1'
`);
    const doc = JSON.parse(cfg) as Doc;
    const node = doc.outbounds.find((o) => (o.tag || "").startsWith("s__"));
    expect(node).toBeTruthy();
    expect(node?.detour).toBeUndefined(); // no self-detour emitted
    expect(node?.detour).not.toBe(node?.tag); // and never its own tag
  });

  it("subscription detour to a same-subscription node resolves to that node's tag", async () => {
    await setup();
    // Two nodes in the same subscription: "Main" detours to "Hop" by display name.
    const lines = [
      JSON.stringify({
        o: {
          type: "vless",
          server: "10.0.0.1",
          server_port: 443,
          uuid: "11111111-1111-1111-1111-111111111111",
        },
        n: "Hop",
        l: null,
      }),
      JSON.stringify({
        o: {
          type: "vless",
          server: "10.0.0.2",
          server_port: 443,
          uuid: "22222222-2222-2222-2222-222222222222",
        },
        n: "Main",
        l: null,
        d: "Hop",
      }),
    ].join("\n");
    await exec(
      `printf '%s\\n' '${lines.replace(/'/g, "'\\''")}' > ${sandboxDir}/subs/sub_s.txt`,
    );
    const cfg = await runGen(`
config outbound 's'
\toption enabled '1'
\toption type 'subscription'
\toption sub_url 'https://x/y'
\toption sub_multi '1'
`);
    const doc = JSON.parse(cfg) as Doc;
    const subNodes = doc.outbounds.filter((o) =>
      (o.tag || "").startsWith("s__"),
    );
    const hop = subNodes.find((o) => o.server === "10.0.0.1");
    const main = subNodes.find((o) => o.server === "10.0.0.2");
    expect(hop).toBeTruthy();
    expect(main).toBeTruthy();
    expect(main?.detour).toBe(hop?.tag as string);
  });

  // ---- C1: import provider urltest/selector groups -------------------------

  const N1 = JSON.stringify({
    o: {
      type: "vless",
      server: "1.1.1.1",
      server_port: 443,
      uuid: "11111111-1111-1111-1111-111111111111",
    },
    n: "LV 1",
    l: null,
  });
  const N2 = JSON.stringify({
    o: {
      type: "vless",
      server: "2.2.2.2",
      server_port: 443,
      uuid: "22222222-2222-2222-2222-222222222222",
    },
    n: "LV 2",
    l: null,
  });

  const leafTags = (doc: Doc): string[] =>
    doc.outbounds
      .map((o) => o.tag || "")
      .filter((t) => t.startsWith("s__") && !t.startsWith("s__grp__"));

  it("import on: a provider urltest group becomes an outbound and main's child", async () => {
    await setup();
    const grp = JSON.stringify({
      g: { type: "urltest", members: ["LV 1", "LV 2"], url: "https://x/g" },
      n: "Latvia",
      m: ["LV 1", "LV 2"],
    });
    await seed("s", [N1, N2, grp]);
    const doc = JSON.parse(
      await runGen(`
config outbound 's'
\toption enabled '1'
\toption type 'subscription'
\toption sub_url 'https://x/y'
\toption sub_multi '1'
\toption sub_import_groups '1'
`),
    ) as Doc;
    const grpOb = doc.outbounds.find(
      (o) => o.type === "urltest" && (o.tag || "").startsWith("s__grp__"),
    );
    expect(grpOb).toBeTruthy();
    expect(grpOb?.url).toBe("https://x/g"); // provider url honored
    expect(grpOb?.outbounds?.length).toBe(2); // both leaves resolved
    const main = doc.outbounds.find((o) => o.tag === "s");
    expect(main?.outbounds).toContain(grpOb?.tag); // group is main's child
  });

  it("import off (absent): no grp__ tag; main is the flat leaf list (regression)", async () => {
    await setup();
    const grp = JSON.stringify({
      g: { type: "urltest", members: ["LV 1", "LV 2"], url: "https://x/g" },
      n: "Latvia",
      m: ["LV 1", "LV 2"],
    });
    await seed("s", [N1, N2, grp]);
    const doc = JSON.parse(
      await runGen(`
config outbound 's'
\toption enabled '1'
\toption type 'subscription'
\toption sub_url 'https://x/y'
\toption sub_multi '1'
`),
    ) as Doc;
    expect(
      doc.outbounds.find((o) => (o.tag || "").startsWith("s__grp__")),
    ).toBeUndefined();
    const leaves = leafTags(doc);
    expect(leaves.length).toBe(2);
    const main = doc.outbounds.find((o) => o.tag === "s");
    // main selector = exactly the flat leaf list, as before groups existed.
    expect((main?.outbounds ?? []).slice().sort()).toEqual(
      leaves.slice().sort(),
    );
  });

  it("member 'direct' is dropped by default but kept with sub_trust_provider=1", async () => {
    const grp = JSON.stringify({
      g: { type: "selector", members: ["LV 1", "direct"] },
      n: "G",
      m: ["LV 1", "direct"],
    });
    const base = `
config outbound 's'
\toption enabled '1'
\toption type 'subscription'
\toption sub_url 'https://x/y'
\toption sub_multi '1'
\toption sub_import_groups '1'
`;

    await setup();
    await seed("s", [N1, grp]);
    let doc = JSON.parse(await runGen(base)) as Doc;
    let g = doc.outbounds.find((o) => (o.tag || "").startsWith("s__grp__"));
    expect(g).toBeTruthy();
    expect(g?.outbounds).not.toContain("direct"); // untrusted → dropped
    expect(g?.outbounds?.length).toBe(1);

    await setup();
    await seed("s", [N1, grp]);
    doc = JSON.parse(
      await runGen(`${base}\toption sub_trust_provider '1'\n`),
    ) as Doc;
    g = doc.outbounds.find((o) => (o.tag || "").startsWith("s__grp__"));
    expect(g).toBeTruthy();
    expect(g?.outbounds).toContain("direct"); // trusted escape hatch
  });

  it("sub_hide_grouped_nodes=1: grouped leaves leave main but stay in the config", async () => {
    await setup();
    const grp = JSON.stringify({
      g: { type: "urltest", members: ["LV 1", "LV 2"] },
      n: "Latvia",
      m: ["LV 1", "LV 2"],
    });
    await seed("s", [N1, N2, grp]);
    const doc = JSON.parse(
      await runGen(`
config outbound 's'
\toption enabled '1'
\toption type 'subscription'
\toption sub_url 'https://x/y'
\toption sub_multi '1'
\toption sub_import_groups '1'
\toption sub_hide_grouped_nodes '1'
`),
    ) as Doc;
    const leaves = leafTags(doc);
    expect(leaves.length).toBe(2);
    const main = doc.outbounds.find((o) => o.tag === "s");
    for (const lt of leaves) expect(main?.outbounds).not.toContain(lt); // hidden from view
    for (const lt of leaves)
      expect(doc.outbounds.some((o) => o.tag === lt)).toBe(true); // still emitted, still routable
    const grpOb = doc.outbounds.find((o) =>
      (o.tag || "").startsWith("s__grp__"),
    );
    expect(main?.outbounds).toContain(grpOb?.tag);
  });

  // ---- Fix wave: C-1 (no dangling refs), I-1 (live depth guard), I-2 (hide) --

  it("C-1 gate: a dropped child group is never referenced (no dangling ref)", async () => {
    await setup();
    // Alpha references Beta; Beta's only member is unresolvable, so Beta drops.
    const alpha = JSON.stringify({
      g: { type: "urltest", members: ["Beta", "LV 1"] },
      n: "Alpha",
      m: ["Beta", "LV 1"],
    });
    const beta = JSON.stringify({
      g: { type: "urltest", members: ["ghost"] },
      n: "Beta",
      m: ["ghost"],
    });
    await seed("s", [N1, alpha, beta]);
    const { doc, stderr } = await runGenErr(`
config outbound 's'
\toption enabled '1'
\toption type 'subscription'
\toption sub_url 'https://x/y'
\toption sub_multi '1'
\toption sub_import_groups '1'
`);
    // The fix builds Beta on demand: it drops at the SOURCE, so Alpha never
    // references it. The buggy static resolve pushed Beta's tag into Alpha and
    // relied on the GEN-1/BLD-7 prune to strip it — logging this exact warning.
    // Its ABSENCE gates C-1 (RED when the fix is reverted).
    expect(stderr).not.toContain("is not a defined outbound");
    // No emitted group references a tag that isn't an emitted outbound.
    const tags = new Set(doc.outbounds.map((o) => o.tag || ""));
    tags.add("direct");
    tags.add("block");
    for (const o of doc.outbounds)
      if (o.type === "urltest" || o.type === "selector")
        for (const m of o.outbounds ?? []) expect(tags.has(m)).toBe(true);
    // And the config stands on its own — valid without the prune's rescue.
    const sbAvail = await exec(
      "command -v sing-box >/dev/null 2>&1 && echo YES || echo NO",
    );
    if (sbAvail.stdout.trim() === "YES") {
      const r = await exec(`sing-box check -c ${sandboxConfig} 2>&1`);
      expect(r.exitCode).toBe(0);
    }
  });

  it("I-1 gate: sub_group_max_depth actually drops over-deep nesting", async () => {
    const outer = JSON.stringify({
      g: { type: "urltest", members: ["Inner", "LV 2"] },
      n: "Outer",
      m: ["Inner", "LV 2"],
    });
    const inner = JSON.stringify({
      g: { type: "urltest", members: ["LV 1"] },
      n: "Inner",
      m: ["LV 1"],
    });
    const base = `
config outbound 's'
\toption enabled '1'
\toption type 'subscription'
\toption sub_url 'https://x/y'
\toption sub_multi '1'
\toption sub_import_groups '1'
`;
    // Identify groups by content, not by hashed tag: Inner is the group holding
    // the LV1 leaf, Outer the one holding the LV2 leaf.
    const analyze = (doc: Doc) => {
      const leaf = (srv: string) =>
        doc.outbounds.find((o) => o.server === srv)?.tag as string;
      const grp = (leafTag: string) =>
        doc.outbounds.find(
          (o) =>
            (o.type === "urltest" || o.type === "selector") &&
            (o.outbounds ?? []).includes(leafTag),
        )?.tag as string;
      const innerTag = grp(leaf("1.1.1.1"));
      const outerTag = grp(leaf("2.2.2.2"));
      const outerOb = doc.outbounds.find((o) => o.tag === outerTag);
      const main = doc.outbounds.find((o) => o.tag === "s");
      return {
        innerTag,
        outerMembers: outerOb?.outbounds ?? [],
        main: main?.outbounds ?? [],
      };
    };

    // Default depth: Outer nests Inner; Inner is not a direct main child.
    await setup();
    await seed("s", [N1, N2, outer, inner]);
    const deep = analyze(JSON.parse(await runGen(base)) as Doc);
    expect(deep.outerMembers).toContain(deep.innerTag);
    expect(deep.main).not.toContain(deep.innerTag);

    // Depth 1: Inner exceeds the limit inside Outer → dropped from Outer and
    // promoted to a top-level main child. The flag changes the emitted set.
    await setup();
    await seed("s", [N1, N2, outer, inner]);
    const shallow = analyze(
      JSON.parse(
        await runGen(`${base}\toption sub_group_max_depth '1'\n`),
      ) as Doc,
    );
    expect(shallow.outerMembers).not.toContain(shallow.innerTag);
    expect(shallow.main).toContain(shallow.innerTag);
    expect(deep.outerMembers).not.toEqual(shallow.outerMembers);

    // Both depths still produce a config sing-box accepts.
    const sbAvail = await exec(
      "command -v sing-box >/dev/null 2>&1 && echo YES || echo NO",
    );
    if (sbAvail.stdout.trim() === "YES") {
      const r = await exec(`sing-box check -c ${sandboxConfig} 2>&1`);
      expect(r.exitCode).toBe(0);
    }
  });

  it("I-2 gate: sub_hide_grouped_nodes toggles a grouped leaf in/out of main", async () => {
    const grp = JSON.stringify({
      g: { type: "urltest", members: ["LV 1"] },
      n: "G",
      m: ["LV 1"],
    });
    const base = `
config outbound 's'
\toption enabled '1'
\toption type 'subscription'
\toption sub_url 'https://x/y'
\toption sub_multi '1'
\toption sub_import_groups '1'
`;
    // hide='0': the grouped leaf ALSO appears as a direct main child.
    await setup();
    await seed("s", [N1, grp]);
    let doc = JSON.parse(
      await runGen(`${base}\toption sub_hide_grouped_nodes '0'\n`),
    ) as Doc;
    let leaf = doc.outbounds.find((o) => o.server === "1.1.1.1")?.tag as string;
    let main = doc.outbounds.find((o) => o.tag === "s");
    expect(main?.outbounds).toContain(leaf);
    expect(doc.outbounds.some((o) => o.tag === leaf)).toBe(true);

    // hide='1': the grouped leaf leaves main but stays emitted in the config.
    await setup();
    await seed("s", [N1, grp]);
    doc = JSON.parse(
      await runGen(`${base}\toption sub_hide_grouped_nodes '1'\n`),
    ) as Doc;
    leaf = doc.outbounds.find((o) => o.server === "1.1.1.1")?.tag as string;
    main = doc.outbounds.find((o) => o.tag === "s");
    expect(main?.outbounds).not.toContain(leaf);
    expect(doc.outbounds.some((o) => o.tag === leaf)).toBe(true);
  });

  it("a 2-cycle of imported groups still passes sing-box check", async () => {
    await setup();
    const gA = JSON.stringify({
      g: { type: "urltest", members: ["Beta", "LV 1"] },
      n: "Alpha",
      m: ["Beta", "LV 1"],
    });
    const gB = JSON.stringify({
      g: { type: "urltest", members: ["Alpha", "LV 1"] },
      n: "Beta",
      m: ["Alpha", "LV 1"],
    });
    await seed("s", [N1, gA, gB]);
    await runGen(`
config outbound 's'
\toption enabled '1'
\toption type 'subscription'
\toption sub_url 'https://x/y'
\toption sub_multi '1'
\toption sub_import_groups '1'
`);
    const sbAvail = await exec(
      "command -v sing-box >/dev/null 2>&1 && echo YES || echo NO",
    );
    if (sbAvail.stdout.trim() !== "YES") return; // sing-box absent — nothing to check
    const r = await exec(`sing-box check -c ${sandboxConfig} 2>&1`);
    expect(r.exitCode).toBe(0);
  });

  // ---- Fix wave 2: empty-kids memo must not poison shallow-buildable groups --

  it("empty-kids memo gate: deep-nested provider groups aren't poisoned by a too-deep first walk", async () => {
    await setup();
    // Chain X→A→B→C→Leaf1 of urltest groups, fed in on-disk order [X,A,B,C].
    // Default depth 3. Building X first: C sits at depth 4 (>3) → path-dropped →
    // B empty → A empty. The buggy memo froze those empties to PERMANENT null, so
    // the outer retry build_group(A,1) — which builds A→B→C(d3)→Leaf1 fine from
    // A's own shallow root — hit the poison and returned null: A and B vanished,
    // only C survived. Not memoizing the empty-kids case lets A and B rebuild.
    const leaf = JSON.stringify({
      o: {
        type: "vless",
        server: "9.9.9.9",
        server_port: 443,
        uuid: "99999999-9999-9999-9999-999999999999",
      },
      n: "Leaf1",
      l: null,
    });
    const gX = JSON.stringify({
      g: { type: "urltest", members: ["A"] },
      n: "X",
      m: ["A"],
    });
    const gA = JSON.stringify({
      g: { type: "urltest", members: ["B"] },
      n: "A",
      m: ["B"],
    });
    const gB = JSON.stringify({
      g: { type: "urltest", members: ["C"] },
      n: "B",
      m: ["C"],
    });
    const gC = JSON.stringify({
      g: { type: "urltest", members: ["Leaf1"] },
      n: "C",
      m: ["Leaf1"],
    });
    await seed("s", [leaf, gX, gA, gB, gC]);
    const doc = JSON.parse(
      await runGen(`
config outbound 's'
\toption enabled '1'
\toption type 'subscription'
\toption sub_url 'https://x/y'
\toption sub_multi '1'
\toption sub_import_groups '1'
`),
    ) as Doc;
    // Identify the groups by structure (their tags are content hashes): C holds
    // the Leaf1 leaf, B holds C, A holds B.
    const leafTag = doc.outbounds.find((o) => o.server === "9.9.9.9")
      ?.tag as string;
    expect(leafTag).toBeTruthy();
    const holderOf = (childTag: string) =>
      doc.outbounds.find(
        (o) =>
          (o.type === "urltest" || o.type === "selector") &&
          (o.outbounds ?? []).includes(childTag),
      )?.tag as string;
    const gCtag = holderOf(leafTag);
    const gBtag = holderOf(gCtag); // group B — poisoned to null when memo reverted
    const gAtag = holderOf(gBtag); // group A — poisoned to null when memo reverted
    // BOTH A and B are emitted as s__grp__ outbounds (not poisoned away). With the
    // memo reverted, B and A are absent, so these tags aren't s__grp__ and fail.
    expect(gBtag).toBeTruthy();
    expect(gBtag.startsWith("s__grp__")).toBe(true);
    expect(gAtag).toBeTruthy();
    expect(gAtag.startsWith("s__grp__")).toBe(true);
    // And the config stands on its own.
    const sbAvail = await exec(
      "command -v sing-box >/dev/null 2>&1 && echo YES || echo NO",
    );
    if (sbAvail.stdout.trim() === "YES") {
      const r = await exec(`sing-box check -c ${sandboxConfig} 2>&1`);
      expect(r.exitCode).toBe(0);
    }
  });
});
