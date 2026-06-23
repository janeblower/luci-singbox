import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

// Port of tests/backend/test_cross_section_refs.sh
// Behavioral cross-section reference validation against generate.uc output:
//   - multi-hop detour chains resolve end-to-end
//   - route resolve action -> dns_server tag resolves
//   - dns_rule.server / rule-set tag resolution
//   - circular detour does not hang/crash; generate succeeds
//   - dangling outbound->outbound detour scrubbed by scrub_dangling_detours
//   - detour to disabled outbound scrubbed
//   - forward reference to valid enabled outbound preserved

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB =
  process.env.SB_VM_LIB ?? `${WORK}/singbox-ui/root/usr/share/singbox-ui/lib`;
const GENERATE_UC = `${WORK}/singbox-ui/root/usr/share/singbox-ui/generate.uc`;
const TMP = `/tmp/sb-xref-${process.pid}`;
const SANDBOX = `${TMP}/sandbox`;
const SANDBOX_CONFIG = `${SANDBOX}/singbox-ui.json`;

async function setup(): Promise<void> {
  await exec(`mkdir -p ${SANDBOX}/subs`);
}

async function teardown(): Promise<void> {
  await exec(`rm -rf ${TMP}`);
}

async function writeCfg(content: string): Promise<void> {
  await putFile(content, `${TMP}/singbox-ui`);
}

async function runGen(): Promise<{ ok: boolean; stderr: string }> {
  const r = await exec(
    `cd ${WORK} && UCI_CONFIG_DIR=${TMP} SINGBOX_TMPDIR=${SANDBOX}/subs SINGBOX_CONFIG=${SANDBOX_CONFIG} ` +
      `ucode -L ${LIB} ${GENERATE_UC} 2>${TMP}/gen.stderr && cp ${SANDBOX_CONFIG} ${TMP}/out.json`,
  );
  if (r.exitCode !== 0) {
    const se = await exec(`cat ${TMP}/gen.stderr 2>/dev/null || true`);
    return { ok: false, stderr: se.stdout };
  }
  return { ok: true, stderr: "" };
}

// Evaluate a ucode expression over the parsed JSON at ${TMP}/out.json.
// Returns the printed value (string/bool/<<UNDEF>>).
async function jeval(expr: string): Promise<string> {
  const r = await exec(
    `cd ${WORK} && ucode -L ${LIB} -e '
let fs=require("fs"); let f=fs.open(ARGV[0],"r"); let d=json(f.read("all")); f.close();
let v; try { v=(${expr}); } catch(e){ v=null; }
if (v===null) print("<<UNDEF>>"); else if (type(v)=="bool") print(v?"true":"false"); else print(v);
' ${TMP}/out.json`,
  );
  return r.stdout.trim();
}

describe("cross_section_refs (detour chains / dangling / circular / resolve)", () => {
  useGuest();

  it("setup", async () => {
    await setup();
    const r = await exec(`[ -d ${SANDBOX} ] && echo ok || echo fail`);
    expect(r.stdout.trim()).toBe("ok");
  });

  // ---- detour chain A->B->C resolves end-to-end ----
  it("detour chain A->B->C: A.detour==B and B.detour==C preserved", async () => {
    await writeCfg(`config outbound 'C'
\toption enabled '1'
\toption type 'direct'

config outbound 'B'
\toption enabled '1'
\toption type 'socks'
\toption server '10.0.0.2'
\toption server_port '1080'
\toption detour 'C'

config outbound 'A'
\toption enabled '1'
\toption type 'socks'
\toption server '10.0.0.1'
\toption server_port '1080'
\toption detour 'B'
`);
    const g = await runGen();
    expect(g.ok).toBe(true);
    const aDetour = await jeval(
      '(function(){for(let o in d.outbounds)if(o.tag=="A")return o.detour;return "<none>";})()',
    );
    expect(aDetour).toBe("B");
    const bDetour = await jeval(
      '(function(){for(let o in d.outbounds)if(o.tag=="B")return o.detour;return "<none>";})()',
    );
    expect(bDetour).toBe("C");
  });

  // ---- route_rule resolve action -> dns_server tag resolves ----
  it("route resolve action references a dns_server tag", async () => {
    await writeCfg(`config dns_server 'up'
\toption enabled '1'
\toption type 'udp'
\toption server '1.1.1.1'

config inbound 'tp'
\toption enabled '1'
\toption protocol 'tproxy'
\toption listen_port '7893'
\toption hijack_dns '0'

config route_rule 'r_resolve'
\toption enabled '1'
\toption type 'default'
\toption action 'resolve'
\toption server 'up'
\tlist domain_suffix '.cn'
`);
    const g = await runGen();
    expect(g.ok).toBe(true);
    const v = await jeval(
      '(function(){for(let r in d.route.rules)if(r.action=="resolve"&&r.server=="up")return true;return false;})()',
    );
    expect(v).toBe("true");
  });

  // ---- dns_rule.server -> dns_server tag resolves; ruleset tag defined ----
  it("dns_rule.server + rule_set tag resolution", async () => {
    await writeCfg(`config dns_server 'fakeip'
\toption enabled '1'
\toption type 'fakeip'
\toption inet4_range '198.18.0.0/15'

config ruleset 'cn'
\toption enabled '1'
\toption type 'remote'
\toption url 'https://example.com/cn.srs'

config dns_rule 'cn_fakeip'
\toption enabled '1'
\toption type 'default'
\tlist rule_set 'cn'
\toption action 'route'
\toption server 'fakeip'
`);
    const g = await runGen();
    expect(g.ok).toBe(true);
    const dnsRoutes = await jeval(
      '(function(){for(let r in d.dns.rules)if(r.server=="fakeip")return true;return false;})()',
    );
    expect(dnsRoutes).toBe("true");
    const rsDefn = await jeval(
      '(function(){for(let e in (d.route.rule_set||[]))if(e.tag=="cn")return true;return false;})()',
    );
    expect(rsDefn).toBe("true");
  });

  // ---- circular detour A->B->A must not hang or crash ----
  it("circular detour A->B->A: generate completes, both hops emitted", async () => {
    await writeCfg(`config outbound 'A'
\toption enabled '1'
\toption type 'socks'
\toption server '10.0.0.1'
\toption server_port '1080'
\toption detour 'B'

config outbound 'B'
\toption enabled '1'
\toption type 'socks'
\toption server '10.0.0.2'
\toption server_port '1080'
\toption detour 'A'
`);
    const g = await runGen();
    expect(g.ok).toBe(true);
    const aPresent = await jeval(
      '(function(){for(let o in d.outbounds)if(o.tag=="A")return true;return false;})()',
    );
    expect(aPresent).toBe("true");
    const bPresent = await jeval(
      '(function(){for(let o in d.outbounds)if(o.tag=="B")return true;return false;})()',
    );
    expect(bPresent).toBe("true");
  });

  // ---- dangling detour to a missing outbound: scrubbed ----
  it("dangling detour to missing outbound: scrubbed from 'real'", async () => {
    await writeCfg(`config outbound 'real'
\toption enabled '1'
\toption type 'socks'
\toption server '10.0.0.1'
\toption server_port '1080'
\toption detour 'ghost'
`);
    const g = await runGen();
    expect(g.ok).toBe(true);
    const realPresent = await jeval(
      '(function(){for(let o in d.outbounds)if(o.tag=="real")return true;return false;})()',
    );
    expect(realPresent).toBe("true");
    const detour = await jeval(
      '(function(){for(let o in d.outbounds)if(o.tag=="real")return o.detour;return "<none>";})()',
    );
    expect(detour).toBe("<<UNDEF>>");
  });

  // ---- detour to a DISABLED outbound is also scrubbed ----
  it("detour to disabled outbound: scrubbed from 'live'", async () => {
    await writeCfg(`config outbound 'gone'
\toption enabled '0'
\toption type 'direct'

config outbound 'live'
\toption enabled '1'
\toption type 'socks'
\toption server '10.0.0.1'
\toption server_port '1080'
\toption detour 'gone'
`);
    const g = await runGen();
    expect(g.ok).toBe(true);
    const detour = await jeval(
      '(function(){for(let o in d.outbounds)if(o.tag=="live")return o.detour;return "<none>";})()',
    );
    expect(detour).toBe("<<UNDEF>>");
  });

  // ---- forward reference to a VALID enabled outbound is PRESERVED ----
  it("forward reference detour to valid enabled outbound: preserved", async () => {
    await writeCfg(`config outbound 'first'
\toption enabled '1'
\toption type 'socks'
\toption server '10.0.0.1'
\toption server_port '1080'
\toption detour 'later'

config outbound 'later'
\toption enabled '1'
\toption type 'direct'
`);
    const g = await runGen();
    expect(g.ok).toBe(true);
    const detour = await jeval(
      '(function(){for(let o in d.outbounds)if(o.tag=="first")return o.detour;return "<none>";})()',
    );
    expect(detour).toBe("later");
  });

  it("teardown", async () => {
    await teardown();
  });
});
