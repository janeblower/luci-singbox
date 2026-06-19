import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

// Port of tests/backend/test_dns_uc.sh
// Tests generate.uc DNS block from dns_server/dns_rule/dns sections via UCI.

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB = `${WORK}/singbox-ui/root/usr/share/singbox-ui/lib`;
const GENERATE_UC = `${WORK}/singbox-ui/root/usr/share/singbox-ui/generate.uc`;

describe("dns_uc (generate.uc DNS block integration)", () => {
  useGuest();

  // Helper: write UCI config, run generate.uc, return parsed JSON output.
  async function runGen(
    label: string,
    uciConfig: string,
  ): Promise<{ json: Record<string, unknown>; raw: string }> {
    const dir = `/tmp/dns_uc_${process.pid}_${label}`;
    const sandboxDir = `${dir}/sandbox`;
    const sandboxConfig = `${sandboxDir}/singbox-ui.json`;
    await exec(`mkdir -p ${sandboxDir}/subs`);
    await putFile(uciConfig, `${dir}/singbox-ui`);
    const r = await exec(
      `cd ${WORK} && UCI_CONFIG_DIR=${dir} SINGBOX_TMPDIR=${sandboxDir}/subs SINGBOX_CONFIG=${sandboxConfig} ucode -L ${LIB} ${GENERATE_UC} >/dev/null 2>&1; rc=$?; if [ $rc -eq 0 ]; then cat ${sandboxConfig}; else echo GENFAIL; fi; rm -rf ${dir}`,
    );
    if (r.stdout.includes("GENFAIL")) {
      throw new Error(`generate.uc failed: ${r.stderr}`);
    }
    return {
      json: JSON.parse(r.stdout) as Record<string, unknown>,
      raw: r.stdout,
    };
  }

  it("typed servers (https/udp/fakeip) + final/strategy emitted correctly", async () => {
    const { raw } = await runGen(
      "typed",
      `
config outbound 'direct'
\toption enabled '1'
\toption type 'interface'
\toption interface 'eth0'

config dns_server 'google'
\toption enabled '1'
\toption type 'https'
\toption server 'dns.google'
\toption server_port '443'
\toption path '/dns-query'
\toption detour 'direct'

config dns_server 'local'
\toption enabled '1'
\toption type 'udp'
\toption server '192.168.1.1'

config dns_server 'fakeip'
\toption enabled '1'
\toption type 'fakeip'
\toption inet4_range '198.18.0.0/15'
\toption inet6_range 'fc00::/18'

config dns 'dns'
\toption final 'google'
\toption strategy 'prefer_ipv4'
`,
    );
    expect(raw).toContain('"dns":');
    expect(raw).toContain('"type": "https"');
    expect(raw).toContain('"server": "dns.google"');
    expect(raw).toContain('"path": "/dns-query"');
    expect(raw).toContain('"detour": "direct"');
    expect(raw).toContain('"type": "udp"');
    expect(raw).toContain('"type": "fakeip"');
    expect(raw).toContain('"inet4_range": "198.18.0.0/15"');
    expect(raw).toContain('"final": "google"');
    expect(raw).toContain('"strategy": "prefer_ipv4"');
  });

  it("dns_rule: rule_set + domains + clash_mode emitted; no synthetic rewrite_ttl 60", async () => {
    const { raw } = await runGen(
      "rules",
      `
config ruleset 'ru'
\toption enabled '1'
\toption type 'remote'
\toption url 'https://example.com/ru.srs'

config dns_server 'fakeip'
\toption enabled '1'
\toption type 'fakeip'
\toption inet4_range '198.18.0.0/15'

config dns_rule 'r1'
\toption enabled '1'
\tlist rule_set 'ru'
\tlist domain_suffix 'example.com'
\tlist domain_suffix 'test.org'
\toption clash_mode 'global'
\toption action 'route'
\toption server 'fakeip'

config dns 'dns'
\toption final 'fakeip'
`,
    );
    expect(raw).toContain('"rules":');
    expect(raw).toContain('"server": "fakeip"');
    expect(raw).toContain('"rule_set":');
    expect(raw).toContain('"example.com"');
    expect(raw).toContain('"clash_mode": "global"');
    expect(raw).not.toContain('"rewrite_ttl": 60');
  });

  it("empty dns_rule (no matchers, no server) is dropped", async () => {
    const { raw } = await runGen(
      "emptyrule",
      `
config dns_server 'g'
\toption enabled '1'
\toption type 'udp'
\toption server '1.1.1.1'

config dns_rule 'empty'
\toption enabled '1'
`,
    );
    expect(raw).not.toContain('"action": "route"');
  });

  it("disabled dns_server is skipped", async () => {
    const { raw } = await runGen(
      "disabled",
      `
config dns_server 'off'
\toption enabled '0'
\toption type 'udp'
\toption server '9.9.9.9'

config dns_server 'on'
\toption enabled '1'
\toption type 'udp'
\toption server '1.1.1.1'
`,
    );
    expect(raw).toContain('"server": "1.1.1.1"');
    expect(raw).not.toContain('"server": "9.9.9.9"');
  });

  it("dns.independent_cache flag becomes boolean true", async () => {
    const { raw } = await runGen(
      "indcache",
      `
config dns_server 'g'
\toption enabled '1'
\toption type 'udp'
\toption server '1.1.1.1'

config dns 'dns'
\toption independent_cache '1'
`,
    );
    expect(raw).toContain('"independent_cache": true');
  });

  it("dns_rule custom rewrite_ttl is preserved", async () => {
    const { raw } = await runGen(
      "rttl",
      `
config ruleset 'rs'
\toption enabled '1'
\toption type 'remote'
\toption url 'https://x/y.srs'

config dns_rule 'rttl'
\toption enabled '1'
\tlist   rule_set 'rs'
\toption action 'route'
\toption server 'fakeip'
\toption rewrite_ttl '300'

config dns_server 'fakeip'
\toption enabled '1'
\toption type 'fakeip'
`,
    );
    expect(raw).toContain('"rewrite_ttl": 300');
  });

  it("dns_rule rewrite_ttl=0 emits 0 (disables TTL rewrite)", async () => {
    const { raw } = await runGen(
      "rttl0",
      `
config ruleset 'rs'
\toption enabled '1'
\toption type 'remote'
\toption url 'https://x/y.srs'

config dns_rule 'rttl0'
\toption enabled '1'
\tlist   rule_set 'rs'
\toption action 'route'
\toption server 'fakeip'
\toption rewrite_ttl '0'

config dns_server 'fakeip'
\toption enabled '1'
\toption type 'fakeip'
`,
    );
    expect(raw).toContain('"rewrite_ttl": 0');
  });

  it("dns_server invalid server_port is omitted (not coerced to 0)", async () => {
    const { raw } = await runGen(
      "badport",
      `
config dns_server 'badport'
\toption enabled '1'
\toption type 'udp'
\toption server '1.1.1.1'
\toption server_port 'notaport'
`,
    );
    expect(raw).not.toContain('"server_port": 0');
  });

  it("dns_server valid server_port 5353 is preserved as integer", async () => {
    const { raw } = await runGen(
      "okport",
      `
config dns_server 'okport'
\toption enabled '1'
\toption type 'udp'
\toption server '1.1.1.1'
\toption server_port '5353'
`,
    );
    expect(raw).toContain('"server_port": 5353');
  });

  it("dns_rule referencing a disabled dns_server is dropped (S3.2)", async () => {
    const { raw } = await runGen(
      "dangling_rule",
      `
config ruleset 'rs'
\toption enabled '1'
\toption type 'remote'
\toption url 'https://x/y.srs'

config dns_server 'live'
\toption enabled '1'
\toption type 'udp'
\toption server '1.1.1.1'

config dns_server 'dead'
\toption enabled '0'
\toption type 'udp'
\toption server '9.9.9.9'

config dns_rule 'dangling'
\toption enabled '1'
\tlist   rule_set 'rs'
\toption action 'route'
\toption server 'dead'
`,
    );
    expect(raw).not.toContain('"server": "dead"');
  });

  it("dns.final referencing a disabled dns_server is dropped (S3.2)", async () => {
    const { raw } = await runGen(
      "dangling_final",
      `
config dns_server 'live'
\toption enabled '1'
\toption type 'udp'
\toption server '1.1.1.1'

config dns 'dns'
\toption final 'ghost'
`,
    );
    expect(raw).not.toContain('"final": "ghost"');
  });

  it("GEN-4: threaded build_rules maps yield byte-identical output to standalone", async () => {
    const dir = `/tmp/dns_uc_${process.pid}_gen4`;
    await exec(`mkdir -p ${dir}`);
    await putFile(
      `
config ruleset 'rs'
\toption enabled '1'
\toption type 'remote'
\toption url 'https://x/y.srs'

config dns_server 'fakeip'
\toption enabled '1'
\toption type 'fakeip'

config dns_rule 'r1'
\toption enabled '1'
\tlist   rule_set 'rs'
\toption action 'route'
\toption server 'fakeip'
`,
      `${dir}/singbox-ui`,
    );
    const r = await exec(
      `cd ${WORK} && UCI_CONFIG_DIR=${dir} ucode -L ${LIB} -e '
let uci = require("uci").cursor(getenv("UCI_CONFIG_DIR"));
let dns = require("dns");
let a = sprintf("%J", dns.build_rules(uci));
let srv = {}; uci.foreach("singbox-ui","dns_server",function(s){ if(s.enabled!=="0") srv[s[".name"]]=true; });
let rse = {}; uci.foreach("singbox-ui","ruleset",function(s){ rse[s[".name"]]=(s.enabled!=="0"); });
let b = sprintf("%J", dns.build_rules(uci, srv, rse));
print(a === b ? "SAME\\n" : sprintf("DIFF\\n a=%s\\n b=%s\\n", a, b));
'; rm -rf ${dir}`,
    );
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("SAME");
  });
});
