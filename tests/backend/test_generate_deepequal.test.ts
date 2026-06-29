// tests/backend/test_generate_deepequal.test.ts — Plan 5: whole-object deep-equal
// of generate.uc's cross-cutting ASSEMBLY (default-outbound injection, dangling
// outbound prune, selector member/default prune) — the layer the per-constructor
// parity suite does NOT cover. ADDED ALONGSIDE the targeted toContain asserts in
// test_generate.test.ts (S3.2 / GEN-1), never replacing them. bun-in-guest.
//
// `toEqual` is a structural deep-equal: object key order is ignored, array order
// IS significant (so ordering regressions are caught too). Expected values were
// bootstrapped from the real generate.uc output and pinned here; a legitimate
// output change is a deliberate update-the-expected diff.
import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB = `${WORK}/singbox-ui/root/usr/share/singbox-ui/lib`;
const GENERATE_UC = `${WORK}/singbox-ui/root/usr/share/singbox-ui/generate.uc`;

describe("generate.uc — whole-object deep-equal (assembly)", () => {
  useGuest();

  // Unique sandbox per case (name-suffixed) so one case's generate output never
  // cross-talks with another's stale singbox-ui.json (paths are local, not
  // module-shared).
  async function setup(name: string) {
    const base = `/tmp/gen_de_${process.pid}_${name}`;
    const subs = `${base}/sandbox/subs`;
    await exec(`mkdir -p ${subs}`);
    return { base, cfgPath: `${base}/sandbox/singbox-ui.json`, subs };
  }

  async function runGen(
    cfgDir: string,
    cfgPath: string,
    subs: string,
    // biome-ignore lint/suspicious/noExplicitAny: in-guest JSON config tree
  ): Promise<any> {
    const r = await exec(
      `cd ${WORK} && UCI_CONFIG_DIR=${cfgDir} SINGBOX_TMPDIR=${subs} SINGBOX_CONFIG=${cfgPath} ucode -L ${LIB} ${GENERATE_UC} >/dev/null 2>&1; rc=$?; if [ $rc -eq 0 ]; then cat ${cfgPath}; else echo GENFAIL; fi`,
    );
    if (r.stdout.includes("GENFAIL"))
      throw new Error(`generate.uc failed: ${r.stderr}`);
    return JSON.parse(r.stdout);
  }

  async function writeCfg(cfgDir: string, content: string) {
    await putFile(content, `${cfgDir}/singbox-ui`);
  }

  // C1: fakeip dns + tproxy inbound, NO outbound -> default-`direct` injection.
  const FX_C1 = `
config dns_server 'fakeip'
\toption enabled '1'
\toption type 'fakeip'
\toption inet4_range '198.18.0.0/15'
\toption inet6_range 'fc00::/18'

config inbound 'tproxy_in'
\toption enabled '1'
\toption protocol 'tproxy'
\toption listen_port '7893'
`;

  // C2: route_rule + route_default referencing ghost outbounds -> dangling prune.
  const FX_C2 = `
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
`;

  // C3: selector with one real + one ghost member + ghost default -> member prune.
  const FX_C3 = `
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
`;

  it("C1 minimal fakeip+tproxy: default-direct injection + fakeip dns + tproxy inbound", async () => {
    const { base, cfgPath, subs } = await setup("c1");
    await writeCfg(base, FX_C1);
    const cfg = await runGen(base, cfgPath, subs);
    // No outbound defined -> exactly the injected default `direct` (generate.uc:63-74).
    expect(cfg.outbounds).toEqual([{ tag: "direct", type: "direct" }]);
    // fakeip dns server assembled as a single object (NOT array-ified).
    expect(cfg.dns).toEqual({
      servers: [
        {
          inet4_range: "198.18.0.0/15",
          inet6_range: "fc00::/18",
          tag: "fakeip",
          type: "fakeip",
        },
      ],
    });
    // tproxy inbound listen-base ("::" is generate.uc's default listen address).
    expect(cfg.inbounds).toEqual([
      { listen: "::", listen_port: 7893, tag: "tproxy_in", type: "tproxy" },
    ]);
    // Minimal config emits no route section (no transparent nft, no route rules).
    expect(cfg.route).toBeUndefined();
  });

  it("C2 dangling outbound refs pruned: rule dropped, final omitted, rule_set survives", async () => {
    const { base, cfgPath, subs } = await setup("c2");
    await writeCfg(base, FX_C2);
    const cfg = await runGen(base, cfgPath, subs);
    // r32's outbound 'ghostob' is dangling -> the whole rule is dropped; the
    // route_default 'ghostfinal' is dangling -> no `final` emitted; the rs32
    // rule_set still survives. No `rules`/`final` keys at all (generate.uc:80-110).
    // ("binary" is the implicit format default for a remote rule-set.)
    expect(cfg.route).toEqual({
      rule_set: [
        {
          format: "binary",
          tag: "rs32",
          type: "remote",
          url: "https://example.com/rs32.srs",
        },
      ],
    });
    // Complements the targeted S3.2 regression (test_generate.test.ts:407-408).
    const raw = JSON.stringify(cfg);
    expect(raw).not.toContain("ghostob");
    expect(raw).not.toContain("ghostfinal");
  });

  it("C3 selector dangling member/default pruned, direct appended", async () => {
    const { base, cfgPath, subs } = await setup("c3");
    await writeCfg(base, FX_C3);
    const cfg = await runGen(base, cfgPath, subs);
    const grp = cfg.outbounds.find((o: { tag: string }) => o.tag === "mygroup");
    // ghostmember dropped from members, ghostdefault dropped (no `default`), realob kept.
    expect(grp).toEqual({
      outbounds: ["realob"],
      tag: "mygroup",
      type: "selector",
    });
    // realob, the selector, then the appended fallback direct — in this order.
    expect(cfg.outbounds.map((o: { tag: string }) => o.tag)).toEqual([
      "realob",
      "mygroup",
      "direct",
    ]);
    // Complements the targeted GEN-1 regression (test_generate.test.ts:432-433).
    const raw = JSON.stringify(cfg);
    expect(raw).not.toContain("ghostmember");
    expect(raw).not.toContain("ghostdefault");
  });
});
