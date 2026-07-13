import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

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
\toption tcp_fast_open '1'
\toption bind_interface 'eth0'
\toption routing_mark '1234'
\toption reuse_addr '1'
\toption netns '/var/run/netns/x'
\toption tcp_keep_alive '5m'
\toption tcp_keep_alive_interval '75s'
\toption disable_tcp_keep_alive '1'

config outbound 'tuic_out'
\toption enabled '1'
\toption type 'tuic'
\toption server 'tuic.example.com'
\toption server_port '443'
\toption server_uuid 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
\toption server_password 'pw'
\toption tls_server_name 'tuic.example.com'
\toption quic_initial_packet_size '1200'
\toption quic_disable_path_mtu_discovery '1'

config outbound 'trojan_out'
\toption enabled '1'
\toption type 'trojan'
\toption server 'trojan.example.com'
\toption server_port '443'
\toption server_password 'pw'
\toption tls_enabled '1'
\toption tls_server_name 'trojan.example.com'
\toption tls_kernel_tx '1'
\toption tls_kernel_rx '1'

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

      // The version gate ADAPTED to the core that is really installed here (no
      // SINGBOX_CORE_VERSION pin on the generate.uc run above) — assert what it
      // decided, keyed to that core, so "the gate dropped everything" cannot pass
      // as "the core accepted everything". `sing-box check` below then rules on it.
      const mx =
        '(function(){for(let i in d.inbounds)if(i.tag=="mixed_in")return i;return {};})()';
      const core = (await exec("sing-box version 2>/dev/null | head -1"))
        .stdout;
      const v = core.match(/version (\d+)\.(\d+)/);
      console.log(`[e2e] core under test: ${core.trim() || "not detected"}`);
      // No core, no gate: helpers.core_at_least() is fail-open, so an undetectable
      // version emits everything. Mirror that here rather than assume 1.12.
      const atLeast = (want: number) =>
        !v || Number(v[1]) > 1 || Number(v[2]) >= want;
      // 1.12 set: bind_interface / routing_mark / reuse_addr / netns.
      expect(await jpath(`${mx}.bind_interface`, tmpF)).toBe(
        atLeast(12) ? "eth0" : "<<UNDEF>>",
      );
      expect(await jpath(`${mx}.routing_mark`, tmpF)).toBe(
        atLeast(12) ? "1234" : "<<UNDEF>>",
      );
      // 1.13 set: the keep-alive trio. Stock OpenWrt still ships 1.12 -> gated off.
      expect(await jpath(`${mx}.tcp_keep_alive`, tmpF)).toBe(
        atLeast(13) ? "5m" : "<<UNDEF>>",
      );
      // 1.14: quic. No released core has it yet -> absent everywhere today.
      const tu =
        '(function(){for(let o in d.outbounds)if(o.tag=="tuic_out")return o;return {};})()';
      expect(await jpath(`${tu}.initial_packet_size`, tmpF)).toBe(
        atLeast(14) ? "1200" : "<<UNDEF>>",
      );
    } finally {
      await exec(`rm -f ${tmpF}`);
    }

    // sing-box check — the one lane that hands a GENERATED config to a REAL core.
    //
    // The seed above deliberately sets every version-gated key the builder ships:
    // the listen 1.12 set (bind_interface / routing_mark / reuse_addr / netns), the
    // listen 1.13 keep-alive trio, quic's 1.14 pair and kTLS's 1.13 pair. The
    // invariant is core-agnostic: whatever core is installed, what we generate must
    // be accepted by it. On the guest's stock 1.12 the gate has to strip the 1.13/
    // 1.14 keys (an unknown key is not ignored — sing-box refuses the WHOLE config
    // and the daemon never starts), and the 1.12-labelled keys have to be ones a
    // real 1.12 actually knows. Parity builds JSON and never runs the core, so a
    // wrong min_version label can only be caught here.
    const sbAvail = await exec(
      "command -v sing-box >/dev/null 2>&1 && echo YES || echo NO",
    );
    if (sbAvail.stdout.trim() === "YES") {
      const cfgF = `/tmp/e2e_sbcheck_${process.pid}.json`;
      await putFile(r.stdout, cfgF);
      const ver = await exec("sing-box version 2>&1 | head -1");
      const sbR = await exec(`sing-box check -c ${cfgF} 2>&1`);
      await exec(`rm -f ${cfgF}`);
      if (sbR.exitCode !== 0) {
        throw new Error(
          `sing-box check rejected the generated config (${ver.stdout.trim()}):\n${sbR.stdout}`,
        );
      }
    }
  });
});
