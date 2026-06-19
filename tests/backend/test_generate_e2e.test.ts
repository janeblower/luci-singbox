import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

// Port of tests/backend/test_generate_e2e.sh
const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB = `${WORK}/singbox-ui/root/usr/share/singbox-ui/lib`;
const GENERATE_UC = `${WORK}/singbox-ui/root/usr/share/singbox-ui/generate.uc`;

describe("generate_e2e (representative full config through prod argv)", () => {
  useGuest();

  async function jpath(expr: string, file: string): Promise<string> {
    const r = await exec(
      `cd ${WORK} && ucode -L ${LIB} -e 'let fs=require("fs"); let f=fs.open(ARGV[0],"r"); let d=json(f.read("all")); f.close(); let v; try { v=(${expr}); } catch(e){ v=null; } if(v===null) print("<<UNDEF>>"); else if(type(v)=="bool") print(v?"true":"false"); else print(v);' ${file}`,
    );
    return r.stdout.trim();
  }

  it("representative full config through prod argv", async () => {
    const dir = `/tmp/e2e_${process.pid}`;
    const sandboxDir = `${dir}/sandbox`;
    const sandboxConfig = `${sandboxDir}/singbox-ui.json`;
    await exec(`mkdir -p ${sandboxDir}/subs`);

    const uciConfig = `
config log 'log'
\toption enabled '1'
\toption level 'info'

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

config inbound 'mixed_in'
\toption enabled '1'
\toption protocol 'mixed'
\toption listen_port '1080'

config outbound 'my_vless'
\toption enabled '1'
\toption type 'url'
\toption proxy_url 'vless://aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee@vless.example.com:443?security=tls&sni=vless.example.com'

config outbound 'group'
\toption enabled '1'
\toption type 'selector'
\tlist group_outbounds 'my_vless'
\toption group_default 'my_vless'

config ruleset 'geosite_cn'
\toption enabled '1'
\toption type 'remote'
\toption url 'https://example.com/geosite-cn.srs'
\toption format 'binary'

config route_rule 'rule_cn'
\toption enabled '1'
\tlist rule_set 'geosite_cn'
\toption action 'route'
\toption outbound 'group'

config dns_rule 'cn_fakeip'
\toption enabled '1'
\toption type 'default'
\tlist rule_set 'geosite_cn'
\toption action 'route'
\toption server 'fakeip'

config route_default 'route_default'
\toption action 'route'
\toption outbound 'group'

config cache 'cache'
\toption enabled '1'

config clash_api 'clash_api'
\toption enabled '1'
\toption listen '127.0.0.1'
\toption port '9090'
\toption secret 'sekret'
`;
    await putFile(uciConfig, `${dir}/singbox-ui`);

    const r = await exec(
      `cd ${WORK} && UCI_CONFIG_DIR=${dir} SINGBOX_TMPDIR=${sandboxDir}/subs SINGBOX_CONFIG=${sandboxConfig} ucode -L ${LIB} ${GENERATE_UC} >/dev/null 2>&1; rc=$?; if [ $rc -eq 0 ]; then cat ${sandboxConfig}; else echo GENFAIL; fi; rm -rf ${dir}`,
    );
    if (r.stdout.includes("GENFAIL")) {
      throw new Error(`generate.uc failed: ${r.stderr}`);
    }

    // Write JSON to temp file for jpath queries
    const tmpF = `/tmp/e2e_out_${process.pid}.json`;
    await putFile(r.stdout, tmpF);

    try {
      // top-level JSON is well-formed + every section present at its exact path
      expect(await jpath("d.log.level", tmpF)).toBe("info");
      expect(await jpath('type(d.dns.servers)=="array"', tmpF)).toBe("true");
      expect(await jpath("d.dns.final", tmpF)).toBe("google");
      expect(await jpath("length(d.inbounds)>=2", tmpF)).toBe("true");
      expect(await jpath("length(d.outbounds)>=1", tmpF)).toBe("true");
      expect(await jpath("d.route.rules[0].action", tmpF)).toBe("hijack-dns");
      expect(
        await jpath(
          'type(d.route.rule_set)=="array" && length(d.route.rule_set)>=1',
          tmpF,
        ),
      ).toBe("true");
      expect(
        await jpath(
          'type(d.dns.rules)=="array" && length(d.dns.rules)>=1',
          tmpF,
        ),
      ).toBe("true");
      expect(
        await jpath(
          '(function(){for(let o in d.outbounds)if(o.tag=="group")return o.type=="selector";return false;})()',
          tmpF,
        ),
      ).toBe("true");
      expect(
        await jpath("d.experimental.clash_api.external_controller", tmpF),
      ).toBe("127.0.0.1:9090");
      expect(
        await jpath('type(d.experimental.cache_file)=="object"', tmpF),
      ).toBe("true");
    } finally {
      await exec(`rm -f ${tmpF}`);
    }

    // sing-box check
    const sbAvail = await exec(
      "command -v sing-box >/dev/null 2>&1 && echo YES || echo NO",
    );
    if (sbAvail.stdout.trim() === "YES") {
      const cfgF = `/tmp/e2e_sbcheck_${process.pid}.json`;
      await putFile(r.stdout, cfgF);
      const sbR = await exec(`sing-box check -c ${cfgF} 2>&1`);
      await exec(`rm -f ${cfgF}`);
      expect(sbR.exitCode).toBe(0);
    }
  });
});
