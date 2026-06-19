import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

// Port of tests/backend/test_generate.sh
const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB = `${WORK}/singbox-ui/root/usr/share/singbox-ui/lib`;
const GENERATE_UC = `${WORK}/singbox-ui/root/usr/share/singbox-ui/generate.uc`;

let sandboxDir = "";
let sandboxConfig = "";

describe("generate (generate.uc end-to-end)", () => {
  useGuest();

  async function setup() {
    const base = `/tmp/gen_main_${process.pid}`;
    sandboxDir = `${base}/sandbox`;
    sandboxConfig = `${sandboxDir}/singbox-ui.json`;
    await exec(`mkdir -p ${sandboxDir}/subs`);
    return base;
  }

  async function runGen(
    cfgDir: string,
    extraEnv = "",
  ): Promise<{ raw: string }> {
    const r = await exec(
      `cd ${WORK} && ${extraEnv} UCI_CONFIG_DIR=${cfgDir} SINGBOX_TMPDIR=${sandboxDir}/subs SINGBOX_CONFIG=${sandboxConfig} ucode -L ${LIB} ${GENERATE_UC} >/dev/null 2>&1; rc=$?; if [ $rc -eq 0 ]; then cat ${sandboxConfig}; else echo GENFAIL; fi`,
    );
    if (r.stdout.includes("GENFAIL"))
      throw new Error(`generate.uc failed: ${r.stderr}`);
    return { raw: r.stdout };
  }

  async function writeCfg(cfgDir: string, content: string) {
    await putFile(content, `${cfgDir}/singbox-ui`);
  }

  async function jpath(expr: string, file: string): Promise<string> {
    const r = await exec(
      `cd ${WORK} && ucode -L ${LIB} -e 'let fs=require("fs"); let f=fs.open(ARGV[0],"r"); let d=json(f.read("all")); f.close(); let v; try { v=(${expr}); } catch(e){ v=null; } if(v===null) print("<<UNDEF>>"); else if(type(v)=="bool") print(v?"true":"false"); else print(v);' ${file}`,
    );
    return r.stdout.trim();
  }

  it("fakeip dns_server + tproxy inbound", async () => {
    const base = await setup();
    await writeCfg(
      base,
      `
config dns_server 'fakeip'
\toption enabled '1'
\toption type 'fakeip'
\toption inet4_range '198.18.0.0/15'
\toption inet6_range 'fc00::/18'

config inbound 'tproxy_in'
\toption enabled '1'
\toption protocol 'tproxy'
\toption listen_port '7893'
`,
    );
    const { raw } = await runGen(base);
    expect(raw).toContain('"type": "fakeip"');
    expect(raw).toContain('"inet4_range": "198.18.0.0/15"');
    expect(raw).toContain('"inet6_range": "fc00::/18"');
    expect(raw).toContain('"type": "tproxy"');
    expect(raw).toContain('"listen_port": 7893');
    // Must NOT emit as array
    expect(raw).not.toMatch(/"inet4_range":\s*\[/);

    // Atomic publish: no orphan tmpfiles after happy-path
    const orphanR = await exec(
      `find ${sandboxDir} -maxdepth 1 -name 'singbox-ui.json.tmp.*' 2>/dev/null | wc -l`,
    );
    expect(parseInt(orphanR.stdout.trim())).toBe(0);

    // generate.uc uses fs.rename + atomic publish pattern (check on guest)
    const renameR = await exec(
      `grep -q 'fs.rename' ${GENERATE_UC} && echo YES || echo NO`,
    );
    expect(renameR.stdout.trim()).toBe("YES");
    const tmpR = await exec(
      `grep -qE 'publish_atomic|\\.tmp\\.' ${GENERATE_UC} && echo YES || echo NO`,
    );
    expect(tmpR.stdout.trim()).toBe("YES");
  });

  it("atomic publish: no tmp leak when cannot open tmpfile", async () => {
    const base = await setup();
    await writeCfg(
      base,
      `
config dns_server 'fakeip'
\toption enabled '1'
\toption type 'fakeip'
\toption inet4_range '198.18.0.0/15'
`,
    );
    const badDir = `/tmp/gen_main_${process.pid}_does-not-exist/sub`;
    const r = await exec(
      `cd ${WORK} && UCI_CONFIG_DIR=${base} SINGBOX_TMPDIR=${sandboxDir}/subs SINGBOX_CONFIG=${badDir}/config.json ucode -L ${LIB} ${GENERATE_UC} >/dev/null 2>&1; echo "EXIT:$?"`,
    );
    expect(r.stdout).not.toContain("EXIT:0");
    // No tmpfiles leaked
    const leaked = await exec(
      `find /tmp -name 'config.json.tmp.*' 2>/dev/null | wc -l`,
    );
    expect(parseInt(leaked.stdout.trim())).toBe(0);
  });

  it("proxy via interface", async () => {
    const base = await setup();
    await writeCfg(
      base,
      `
config outbound 'via_wg0'
\toption type 'interface'
\toption interface 'wg0'
`,
    );
    const { raw } = await runGen(base);
    expect(raw).toContain('"tag": "via_wg0"');
    expect(raw).toContain('"bind_interface": "wg0"');
  });

  it("bind_interface honours SINGBOX_DEV_<iface> resolver override", async () => {
    const base = await setup();
    await writeCfg(
      base,
      `
config outbound 'wan_out'
\toption type 'interface'
\toption interface 'wan'
`,
    );
    const { raw } = await runGen(base, "SINGBOX_DEV_wan=eth0");
    expect(raw).toContain('"bind_interface": "eth0"');
  });

  it("vless:// URL", async () => {
    const base = await setup();
    await writeCfg(
      base,
      `
config outbound 'my_vless'
\toption type 'url'
\toption proxy_url 'vless://test-uuid-1234@example.com:443?security=tls&sni=example.com&type=tcp'
`,
    );
    const { raw } = await runGen(base);
    expect(raw).toContain('"type": "vless"');
    expect(raw).toContain('"uuid": "test-uuid-1234"');
    expect(raw).toContain('"server": "example.com"');
    expect(raw).toContain('"server_port": 443');
    expect(raw).toContain('"enabled": true');
  });

  it("hy2:// URL", async () => {
    const base = await setup();
    await writeCfg(
      base,
      `
config outbound 'my_hy2'
\toption type 'url'
\toption proxy_url 'hy2://mypassword@vpn.example.com:8443?sni=vpn.example.com'
`,
    );
    const { raw } = await runGen(base);
    expect(raw).toContain('"type": "hysteria2"');
    expect(raw).toContain('"password": "mypassword"');
    expect(raw).toContain('"server": "vpn.example.com"');
  });

  it("outbound without type is skipped", async () => {
    const base = await setup();
    await writeCfg(
      base,
      `
config outbound 'leftover_direct_out'
\toption action 'direct'
`,
    );
    const { raw } = await runGen(base);
    expect(raw).not.toContain('"tag": "leftover_direct_out"');
  });

  it("type=subscription outbound", async () => {
    const base = await setup();
    await exec(
      `printf 'vless://sub-uuid-9999@sub.example.com:443?security=tls&sni=sub.example.com\\n' > ${sandboxDir}/subs/sub_my_sub_out.txt`,
    );
    await writeCfg(
      base,
      `
config outbound 'my_sub_out'
\toption enabled '1'
\toption type 'subscription'
\toption sub_url 'https://sub.example.com/config'
\toption sub_interval '3600'
`,
    );
    const { raw } = await runGen(base);
    expect(raw).toContain('"tag": "my_sub_out"');
    expect(raw).toContain('"type": "vless"');
    expect(raw).toContain('"uuid": "sub-uuid-9999"');
    expect(raw).toContain('"server": "sub.example.com"');
  });

  it("ruleset + route_rule basic", async () => {
    const base = await setup();
    await writeCfg(
      base,
      `
config outbound 'my_vless'
\toption enabled '1'
\toption type 'url'
\toption proxy_url 'vless://uuid-aaaa@vless.example.com:443?security=tls&sni=vless.example.com'

config ruleset 'geosite_cn'
\toption enabled '1'
\toption type 'remote'
\toption url 'https://example.com/geosite-cn.srs'
\toption format 'binary'

config ruleset 'geoip_ru'
\toption enabled '1'
\toption type 'local'
\toption path '/etc/singbox-ui/rules/ru.json'
\toption format 'source'

config route_rule 'rule_cn_vless'
\toption enabled '1'
\tlist rule_set 'geosite_cn'
\toption action 'route'
\toption outbound 'my_vless'

config route_rule 'rule_ru_direct'
\toption enabled '1'
\tlist rule_set 'geoip_ru'
\toption action 'route'
\toption outbound 'direct'
`,
    );
    const { raw } = await runGen(base);
    expect(raw).toContain('"rules":');
    expect(raw).toContain('"rule_set":');
    expect(raw).toContain('"tag": "geosite_cn"');
    expect(raw).toContain('"tag": "geoip_ru"');
    expect(raw).toContain('"type": "remote"');
    expect(raw).toContain('"type": "local"');
    expect(raw).toContain('"path": "/etc/singbox-ui/rules/ru.json"');
    expect(raw).toContain('"format": "binary"');
    expect(raw).toContain('"format": "source"');
    expect(raw).toContain('"outbound": "my_vless"');
    expect(raw).toContain('"outbound": "direct"');
  });

  it("ruleset update_interval -> rule_set emits duration string", async () => {
    const base = await setup();
    await writeCfg(
      base,
      `
config ruleset 'auto_rs'
\toption enabled '1'
\toption type 'remote'
\toption url 'https://example.com/auto.srs'
\toption format 'binary'
\toption nft_rules '0'
\toption update_interval '86400'

config ruleset 'no_iv_rs'
\toption enabled '1'
\toption type 'remote'
\toption url 'https://example.com/noiv.srs'
\toption format 'binary'

config route_rule 'rule_auto'
\toption enabled '1'
\tlist rule_set 'auto_rs'
\tlist rule_set 'no_iv_rs'
\toption action 'route'
\toption outbound 'direct'
`,
    );
    const { raw } = await runGen(base);
    expect(raw).toContain('"update_interval": "86400s"');
    // Exactly one occurrence
    const countR = await exec(
      `echo ${JSON.stringify(raw)} | grep -o '"update_interval"' | wc -l`,
    );
    expect(parseInt(countR.stdout.trim())).toBe(1);
  });

  it("disabled ruleset skipped", async () => {
    const base = await setup();
    await writeCfg(
      base,
      `
config ruleset 'geo_off'
\toption enabled '0'
\toption type 'remote'
\toption url 'https://example.com/off.srs'
\toption format 'binary'

config ruleset 'geo_on'
\toption enabled '1'
\toption type 'remote'
\toption url 'https://example.com/on.srs'
\toption format 'binary'

config route_rule 'rule_mix'
\toption enabled '1'
\tlist rule_set 'geo_off'
\tlist rule_set 'geo_on'
\toption action 'route'
\toption outbound 'direct'
`,
    );
    const { raw } = await runGen(base);
    expect(raw).toContain('"tag": "geo_on"');
    expect(raw).not.toContain('"tag": "geo_off"');
  });

  it("duplicate ruleset deduplicated", async () => {
    const base = await setup();
    await writeCfg(
      base,
      `
config ruleset 'dup_rs'
\toption enabled '1'
\toption type 'remote'
\toption url 'https://example.com/dup.srs'
\toption format 'binary'

config route_rule 'rule_a'
\toption enabled '1'
\tlist rule_set 'dup_rs'
\toption action 'route'
\toption outbound 'direct'

config route_rule 'rule_b'
\toption enabled '1'
\tlist rule_set 'dup_rs'
\toption action 'reject'
`,
    );
    const { raw } = await runGen(base);
    const countR = await exec(
      `echo ${JSON.stringify(raw)} | grep -o '"tag": "dup_rs"' | wc -l`,
    );
    expect(parseInt(countR.stdout.trim())).toBe(1);
    expect(raw).toContain('"outbound": "direct"');
    expect(raw).toContain('"action": "route"');
    expect(raw).toContain('"action": "reject"');
    expect(raw).not.toContain('"outbound": "block"');
    expect(raw).not.toContain('"type": "block"');
  });

  it("route_default action=reject emits trailing catch-all", async () => {
    const base = await setup();
    await writeCfg(
      base,
      `
config inbound 'tproxy_in'
\toption enabled '1'
\toption protocol 'tproxy'
\toption listen_port '7893'
\toption hijack_dns '0'

config route_default 'route_default'
\toption action 'reject'
`,
    );
    const { raw } = await runGen(base);
    expect(raw).not.toContain('"final":');
    expect(raw).toContain('"action": "reject"');
    expect(raw).not.toContain('"type": "block"');
  });

  it("dns_rule emits dns.rules entry (S3.1)", async () => {
    const base = await setup();
    await writeCfg(
      base,
      `
config dns_server 'fakeip'
\toption enabled '1'
\toption type 'fakeip'
\toption inet4_range '198.18.0.0/15'

config ruleset 'geosite_cn'
\toption enabled '1'
\toption type 'remote'
\toption url 'https://example.com/geosite-cn.srs'

config dns_rule 'cn_fakeip'
\toption enabled '1'
\toption type 'default'
\tlist rule_set 'geosite_cn'
\toption action 'route'
\toption server 'fakeip'
`,
    );
    const { raw } = await runGen(base);
    expect(raw).toContain('"dns":');
    expect(raw).toContain('"rules":');
    expect(raw).toContain('"rule_set":');
    expect(raw).toContain('"server": "fakeip"');
    // S3.1: dns-only ruleset must be defined in route.rule_set
    expect(raw).toContain("https://example.com/geosite-cn.srs");
  });

  it("S3.2: dangling outbound refs in route rules/final dropped", async () => {
    const base = await setup();
    await writeCfg(
      base,
      `
config ruleset 'rs32'
\toption enabled '1'
\toption type 'remote'
\toption url 'https://example.com/rs32.srs'

config route_rule 'r32'
\toption enabled '1'
\tlist   rule_set 'rs32'
\toption action 'route'
\toption outbound 'ghostob'

config route_default 'route_default'
\toption action 'route'
\toption outbound 'ghostfinal'
`,
    );
    const { raw } = await runGen(base);
    expect(raw).not.toContain('"outbound": "ghostob"');
    expect(raw).not.toContain("ghostfinal");
  });

  it("GEN-1: selector dangling member/default pruned", async () => {
    const base = await setup();
    await writeCfg(
      base,
      `
config outbound 'realob'
\toption enabled '1'
\toption type 'vless'
\toption server '1.2.3.4'
\toption server_port '443'
\toption uuid '11111111-1111-1111-1111-111111111111'

config outbound 'mygroup'
\toption enabled '1'
\toption type 'selector'
\tlist   group_outbounds 'realob'
\tlist   group_outbounds 'ghostmember'
\toption group_default 'ghostdefault'
`,
    );
    const { raw } = await runGen(base);
    expect(raw).not.toContain("ghostmember");
    expect(raw).not.toContain("ghostdefault");
    expect(raw).toContain('"realob"');
  });

  it("BLD-7: member-less selector group dropped entirely", async () => {
    const base = await setup();
    await writeCfg(
      base,
      `
config outbound 'deadgroup'
\toption enabled '1'
\toption type 'selector'
\tlist   group_outbounds 'nope1'
\tlist   group_outbounds 'nope2'
`,
    );
    const { raw } = await runGen(base);
    expect(raw).not.toContain('"tag": "deadgroup"');
    expect(raw).not.toContain('"outbounds": []');
  });

  it("GEN-3: stale sub_selector_type clamps to selector", async () => {
    const base = await setup();
    await exec(
      `printf 'vless://u@host:443?security=tls#A\\n' > ${sandboxDir}/subs/sub_subClamp.txt`,
    );
    await writeCfg(
      base,
      `
config outbound 'subClamp'
\toption type 'subscription'
\toption sub_url 'http://example.test/x'
\toption sub_multi '1'
\toption sub_selector_type 'bogusvalue'
`,
    );
    const { raw } = await runGen(base);
    // Write JSON to a temp file then jpath check
    const tmpF = `/tmp/gen_main_${process.pid}_gen3.json`;
    await exec(`cat > ${tmpF} << 'ENDJSON'\n${raw}\nENDJSON`);
    const got = await jpath(
      '(function(){for (let o in d.outbounds) if (o.tag=="subClamp") return o.type; return "<none>";})()',
      tmpF,
    );
    expect(got).toBe("selector");
    await exec(`rm -f ${tmpF}`);
  });

  it("GEN-2: post_process pipeline runs after config.route assembly", async () => {
    // Mirror shell awk check: run_pipeline line must appear after config.route={} line
    const r = await exec(
      `awk '/config\\.route[ ]*=[ ]*\\{\\}/ { route_line=NR } /post_process\\.run_pipeline/ { pipe_line=NR } END { if (route_line==0||pipe_line==0) { print "MISSING"; exit 1 } if (pipe_line>route_line) { print "OK" } else { print "BAD" } }' ${GENERATE_UC}`,
    );
    expect(r.stdout.trim()).toBe("OK");
  });

  it("S3.3: default_domain_resolver for DNS-only config", async () => {
    const base = await setup();
    await writeCfg(
      base,
      `
config dns_server 'up'
\toption enabled '1'
\toption type 'udp'
\toption server '1.1.1.1'
`,
    );
    const { raw } = await runGen(base);
    expect(raw).toContain('"default_domain_resolver":');
    expect(raw).toContain('"server": "up"');
  });

  it("subscription urltest emits sub_urltest_url", async () => {
    const base = await setup();
    await exec(
      `printf 'vless://u@host:443?security=tls#A\\n' > ${sandboxDir}/subs/sub_subUT.txt`,
    );
    await writeCfg(
      base,
      `
config outbound 'subUT'
\toption type 'subscription'
\toption sub_url 'http://example.test/x'
\toption sub_multi '1'
\toption sub_selector_type 'urltest'
\toption sub_urltest_url 'https://probe.example/204'
`,
    );
    const { raw } = await runGen(base);
    expect(raw).toContain('"type": "urltest"');
    expect(raw).toContain('"url": "https://probe.example/204"');
  });

  it("subscription urltest without sub_urltest_url omits url", async () => {
    const base = await setup();
    await exec(
      `printf 'vless://u@host:443?security=tls#A\\n' > ${sandboxDir}/subs/sub_subUT2.txt`,
    );
    await writeCfg(
      base,
      `
config outbound 'subUT2'
\toption type 'subscription'
\toption sub_url 'http://example.test/x'
\toption sub_multi '1'
\toption sub_selector_type 'urltest'
`,
    );
    const { raw } = await runGen(base);
    expect(raw).toContain('"type": "urltest"');
    expect(raw).not.toContain('"url":');
  });

  it("log section absent → no log key in JSON", async () => {
    const base = await setup();
    await writeCfg(base, "");
    const { raw } = await runGen(base);
    expect(raw).not.toContain('"log":');
  });

  it("log.enabled=0 → log:{disabled:true}", async () => {
    const base = await setup();
    await writeCfg(
      base,
      `
config log 'log'
\toption enabled '0'
`,
    );
    const { raw } = await runGen(base);
    expect(raw).toContain('"disabled": true');
  });

  it("log.enabled=1 level=debug output=/tmp/x.log", async () => {
    const base = await setup();
    await writeCfg(
      base,
      `
config log 'log'
\toption enabled '1'
\toption level 'debug'
\toption output '/tmp/x.log'
`,
    );
    const { raw } = await runGen(base);
    expect(raw).toContain('"level": "debug"');
    expect(raw).toContain('"output": "/tmp/x.log"');
    expect(raw).toContain('"timestamp": true');
    expect(raw).toContain('"disabled": false');
  });

  it("log.enabled=1 without output omits output field", async () => {
    const base = await setup();
    await writeCfg(
      base,
      `
config log 'log'
\toption enabled '1'
\toption level 'info'
`,
    );
    const { raw } = await runGen(base);
    expect(raw).toContain('"level": "info"');
    // Extract just the log block and check no output key
    const logMatch = raw.match(/"log":\s*\{[^}]*\}/);
    if (logMatch) {
      expect(logMatch[0]).not.toContain('"output"');
    } else {
      // log key exists somewhere - just verify output not present
      expect(raw).not.toContain('"output":');
    }
  });

  it("cache.enabled=0 → no experimental block", async () => {
    const base = await setup();
    await writeCfg(
      base,
      `
config cache 'cache'
\toption enabled '0'
`,
    );
    const { raw } = await runGen(base);
    const tmpF = `/tmp/gen_cache0_${process.pid}.json`;
    await putFile(raw, tmpF);
    const got = await jpath("d.experimental", tmpF);
    expect(got).toBe("<<UNDEF>>");
    await exec(`rm -f ${tmpF}`);
  });

  it("cache.enabled=1 with fakeip dns_server and store_fakeip", async () => {
    const base = await setup();
    await writeCfg(
      base,
      `
config dns_server 'fakeip'
\toption enabled '1'
\toption type 'fakeip'
\toption inet4_range '198.18.0.0/15'

config cache 'cache'
\toption enabled '1'
\toption store_fakeip '1'
\toption storage 'custom'
\toption path '/tmp/test-cache.db'
`,
    );
    const { raw } = await runGen(base);
    expect(raw).toContain('"experimental":');
    expect(raw).toContain('"cache_file":');
    expect(raw).toContain('"enabled": true');
    expect(raw).toContain('"path": "/tmp/test-cache.db"');
    expect(raw).toContain('"store_fakeip": true');
  });

  it("store_fakeip suppressed when fakeip dns_server disabled", async () => {
    const base = await setup();
    await writeCfg(
      base,
      `
config dns_server 'fakeip'
\toption enabled '0'
\toption type 'fakeip'

config cache 'cache'
\toption enabled '1'
\toption store_fakeip '1'
`,
    );
    const { raw } = await runGen(base);
    // store_fakeip must not appear inside cache_file block
    expect(raw).not.toContain('"store_fakeip"');
  });

  it("cache.path defaults when empty", async () => {
    const base = await setup();
    await writeCfg(
      base,
      `
config cache 'cache'
\toption enabled '1'
`,
    );
    const { raw } = await runGen(base);
    expect(raw).toContain('"path": "/tmp/singbox-ui-cache.db"');
  });

  it("route.default_domain_resolver auto-picks first non-fakeip dns_server", async () => {
    const base = await setup();
    await writeCfg(
      base,
      `
config dns_server 'fakeip'
\toption enabled '1'
\toption type 'fakeip'
\toption inet4_range '198.18.0.0/15'

config dns_server 'upstream'
\toption enabled '1'
\toption type 'udp'
\toption server '1.1.1.1'

config route_default 'route_default'
\toption action 'route'
\toption outbound 'direct'
`,
    );
    const { raw } = await runGen(base);
    expect(raw).toContain('"route":');
    expect(raw).toContain('"default_domain_resolver":');
    expect(raw).toContain('"server": "upstream"');
  });

  it("dns.default_resolver UCI override wins over auto-pick", async () => {
    const base = await setup();
    await writeCfg(
      base,
      `
config dns_server 'fakeip'
\toption enabled '1'
\toption type 'fakeip'
\toption inet4_range '198.18.0.0/15'

config dns_server 'upstream'
\toption enabled '1'
\toption type 'udp'
\toption server '1.1.1.1'

config dns_server 'override_me'
\toption enabled '1'
\toption type 'udp'
\toption server '9.9.9.9'

config dns 'dns'
\toption default_resolver 'override_me'

config route_default 'route_default'
\toption action 'route'
\toption outbound 'direct'
`,
    );
    const { raw } = await runGen(base);
    expect(raw).toContain('"server": "override_me"');
  });

  it("DNS-only config still emits default_domain_resolver (S3.3)", async () => {
    const base = await setup();
    await writeCfg(
      base,
      `
config dns_server 'upstream'
\toption enabled '1'
\toption type 'udp'
\toption server '1.1.1.1'
`,
    );
    const { raw } = await runGen(base);
    expect(raw).toContain('"default_domain_resolver":');
    expect(raw).toContain('"server": "upstream"');
  });

  it("dns_server detour='direct' scrubbed when auto-injected (empty)", async () => {
    const base = await setup();
    await writeCfg(
      base,
      `
config dns_server 'out_dns'
\toption enabled '1'
\toption type 'https'
\toption server 'dns.google'
\toption server_port '443'
\toption path '/dns-query'
\toption detour 'direct'

config dns 'dns'
\toption final 'out_dns'
`,
    );
    const { raw } = await runGen(base);
    const tmpF = `/tmp/gen_scrub_${process.pid}.json`;
    await putFile(raw, tmpF);
    expect(await jpath("d.dns.servers[0].tag", tmpF)).toBe("out_dns");
    expect(await jpath("d.dns.servers[0].server", tmpF)).toBe("dns.google");
    expect(await jpath("d.dns.servers[0].path", tmpF)).toBe("/dns-query");
    // detour must be scrubbed
    expect(await jpath("d.dns.servers[0].detour", tmpF)).toBe("<<UNDEF>>");
    expect(await jpath("d.dns.final", tmpF)).toBe("out_dns");
    await exec(`rm -f ${tmpF}`);
  });

  it("dns_server detour='direct' preserved when real direct outbound exists", async () => {
    const base = await setup();
    await writeCfg(
      base,
      `
config outbound 'direct'
\toption enabled '1'
\toption type 'interface'
\toption interface 'eth0'

config dns_server 'out_dns'
\toption enabled '1'
\toption type 'https'
\toption server '1.1.1.1'
\toption detour 'direct'
`,
    );
    const { raw } = await runGen(base);
    expect(raw).toContain('"detour": "direct"');
  });

  it("dns_server with detour to a named outbound", async () => {
    const base = await setup();
    await writeCfg(
      base,
      `
config outbound 'my_vless'
\toption enabled '1'
\toption type 'url'
\toption proxy_url 'vless://uuid@host:443?security=tls'

config dns_server 'out_dns'
\toption enabled '1'
\toption type 'https'
\toption server '1.1.1.1'
\toption server_port '443'
\toption path '/dns-query'
\toption detour 'my_vless'
`,
    );
    const { raw } = await runGen(base);
    expect(raw).toContain('"server": "1.1.1.1"');
    expect(raw).toContain('"detour": "my_vless"');
  });

  it("hijack_dns=0 → no hijack rule", async () => {
    const base = await setup();
    await writeCfg(
      base,
      `
config inbound 'tproxy_in'
\toption enabled '1'
\toption protocol 'tproxy'
\toption listen_port '7893'
\toption hijack_dns '0'
`,
    );
    const { raw } = await runGen(base);
    expect(raw).not.toContain('"action": "hijack-dns"');
  });

  it("hijack_dns=1 → first route.rule is {protocol:dns, action:hijack-dns}", async () => {
    const base = await setup();
    await writeCfg(
      base,
      `
config inbound 'tproxy_in'
\toption enabled '1'
\toption protocol 'tproxy'
\toption listen_port '7893'
\toption hijack_dns '1'

config outbound 'p'
\toption type 'interface'
\toption interface 'eth0'

config ruleset 'cn'
\toption enabled '1'
\toption type 'remote'
\toption url 'https://example.com/cn.srs'

config route_rule 'r1'
\toption enabled '1'
\tlist rule_set 'cn'
\toption action 'route'
\toption outbound 'direct'
`,
    );
    const { raw } = await runGen(base);
    const tmpF = `/tmp/gen_hijack_${process.pid}.json`;
    await putFile(raw, tmpF);
    expect(await jpath("d.route.rules[0].protocol", tmpF)).toBe("dns");
    expect(await jpath("d.route.rules[0].action", tmpF)).toBe("hijack-dns");
    expect(await jpath("d.route.rules[1].outbound", tmpF)).toBe("direct");
    await exec(`rm -f ${tmpF}`);
  });

  it("hijack_dns=1 on enabled tproxy inbound emits hijack rule", async () => {
    const base = await setup();
    await writeCfg(
      base,
      `
config inbound 'tproxy_in'
\toption enabled '1'
\toption protocol 'tproxy'
\toption listen_port '7893'
\toption hijack_dns '1'
`,
    );
    const { raw } = await runGen(base);
    expect(raw).toContain('"action": "hijack-dns"');
  });

  it("direct inbound with dns_listener=1 auto-adds hijack-dns route rule", async () => {
    const base = await setup();
    await writeCfg(
      base,
      `
config inbound 'dns_in'
\toption enabled '1'
\toption protocol 'direct'
\toption listen '127.0.0.53'
\toption listen_port '53'
\toption network 'udp'
\toption dns_listener '1'
`,
    );
    const { raw } = await runGen(base);
    expect(raw).toContain('"action": "hijack-dns"');
    expect(raw).toContain('"inbound": "dns_in"');
  });

  it("clash_api.enabled=1 emits experimental.clash_api alongside cache_file", async () => {
    const base = await setup();
    await writeCfg(
      base,
      `
config clash_api 'clash_api'
\toption enabled '1'
\toption listen '127.0.0.1'
\toption port '9090'
\toption secret 'sekret'

config cache 'cache'
\toption enabled '1'
`,
    );
    const { raw } = await runGen(base);
    const tmpF = `/tmp/gen_clash_${process.pid}.json`;
    await putFile(raw, tmpF);
    expect(
      await jpath("d.experimental.clash_api.external_controller", tmpF),
    ).toBe("127.0.0.1:9090");
    expect(await jpath("d.experimental.clash_api.secret", tmpF)).toBe("sekret");
    expect(
      await jpath('type(d.experimental.cache_file) == "object"', tmpF),
    ).toBe("true");
    await exec(`rm -f ${tmpF}`);
  });

  it("clash_api disabled → no clash_api key under experimental", async () => {
    const base = await setup();
    await writeCfg(
      base,
      `
config clash_api 'clash_api'
\toption enabled '0'
`,
    );
    const { raw } = await runGen(base);
    const tmpF = `/tmp/gen_clash0_${process.pid}.json`;
    await putFile(raw, tmpF);
    expect(await jpath("d.experimental.clash_api", tmpF)).toBe("<<UNDEF>>");
    await exec(`rm -f ${tmpF}`);
  });

  it("no orphan tmpfiles after full test run", async () => {
    const orphans = await exec(
      `find ${sandboxDir} -name 'singbox-ui.json.tmp.*' 2>/dev/null | wc -l`,
    );
    expect(parseInt(orphans.stdout.trim())).toBe(0);
  });

  it("sing-box check end-to-end on complete config", async () => {
    const sbCheck = await exec(
      "command -v sing-box >/dev/null 2>&1 && echo YES || echo NO",
    );
    if (sbCheck.stdout.trim() !== "YES") {
      console.log("SKIP sing-box check — sing-box absent");
      return;
    }
    const base = await setup();
    await writeCfg(
      base,
      `
config dns_server 'google'
\toption enabled '1'
\toption type 'https'
\toption server '8.8.8.8'
\toption server_port '443'
\toption path '/dns-query'

config dns_server 'fakeip'
\toption enabled '1'
\toption type 'fakeip'
\toption inet4_range '198.18.0.0/15'
\toption inet6_range 'fc00::/18'

config dns 'dns'
\toption final 'google'
\toption strategy 'prefer_ipv4'

config inbound 'tproxy_in'
\toption enabled '1'
\toption protocol 'tproxy'
\toption listen_port '7893'
\toption hijack_dns '1'

config outbound 'my_vless'
\toption enabled '1'
\toption type 'url'
\toption proxy_url 'vless://aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee@vless.example.com:443?security=tls&sni=vless.example.com'

config ruleset 'geosite_cn'
\toption enabled '1'
\toption type 'remote'
\toption url 'https://example.com/geosite-cn.srs'
\toption format 'binary'

config route_rule 'rule_cn'
\toption enabled '1'
\tlist rule_set 'geosite_cn'
\toption action 'route'
\toption outbound 'my_vless'

config route_default 'route_default'
\toption action 'route'
\toption outbound 'my_vless'
`,
    );
    const { raw } = await runGen(base);
    const cfgF = `/tmp/gen_sbcheck_${process.pid}.json`;
    await putFile(raw, cfgF);
    const r = await exec(`sing-box check -c ${cfgF} 2>&1`);
    expect(r.exitCode).toBe(0);
    await exec(`rm -f ${cfgF}`);
  });
});
