import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

// route_default action=bypass (sing-box 1.13+) and the built-in `wan` outbound.
//
// bypass cannot be expressed as route.final — final is only a tag — so it goes
// out as a trailing matcher-less rule, which in sing-box matches all traffic and
// therefore lands where a final would.
//
// The built-in wan outbound (`builtin '1'`) exists to give the Default route a
// sane target. The user cannot delete it (the UI locks builtin rows), so once
// they route somewhere else it must not linger in the config or on the Dashboard:
// post_process.prune_unreferenced_builtins drops any builtin outbound nothing
// points at.

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB =
  process.env.SB_VM_LIB ?? `${WORK}/singbox-ui/root/usr/share/singbox-ui/lib`;
const GENERATE_UC = `${WORK}/singbox-ui/root/usr/share/singbox-ui/generate.uc`;
const TMP = `/tmp/sb-bypass-${process.pid}`;
const SANDBOX = `${TMP}/sandbox`;
const OUT = `${SANDBOX}/singbox-ui.json`;

const OUTBOUNDS = `config outbound 'wan'
\toption builtin '1'
\toption enabled '1'
\toption type 'direct'

config outbound 'vless_out'
\toption enabled '1'
\toption type 'direct'
`;

interface Cfg {
  outbounds: { tag: string; type: string }[];
  route?: {
    final?: string;
    rules?: { action?: string; outbound?: string }[];
  };
}

async function generate(
  routeDefault: string,
  extra = "",
): Promise<{ cfg: Cfg; err: string }> {
  await exec(`mkdir -p ${SANDBOX}`);
  await putFile(`${OUTBOUNDS}\n${extra}\n${routeDefault}`, `${TMP}/singbox-ui`);
  const r = await exec(
    `cd ${WORK} && UCI_CONFIG_DIR=${TMP} SINGBOX_TMPDIR=${SANDBOX} ` +
      `SINGBOX_CONFIG=${OUT} ucode -L ${LIB} ${GENERATE_UC} 2>${TMP}/err`,
  );
  expect(r.exitCode).toBe(0);
  const body = await exec(`cat ${OUT}`);
  const err = await exec(`cat ${TMP}/err`);
  return { cfg: JSON.parse(body.stdout) as Cfg, err: err.stdout };
}

function tags(cfg: Cfg): string[] {
  return cfg.outbounds.map((o) => o.tag);
}

describe("route_default bypass + builtin wan outbound", () => {
  useGuest();

  it("keeps the builtin wan outbound while the Default route points at it", async () => {
    const { cfg } = await generate(
      `config route_default 'route_default'
\toption action 'route'
\toption outbound 'wan'
`,
    );
    expect(tags(cfg)).toContain("wan");
    expect(cfg.route?.final).toBe("wan");
  });

  it("drops the builtin wan outbound once nothing references it", async () => {
    const { cfg } = await generate(
      `config route_default 'route_default'
\toption action 'route'
\toption outbound 'vless_out'
`,
    );
    // The user routed elsewhere — the undeletable builtin must not linger.
    expect(tags(cfg)).not.toContain("wan");
    expect(tags(cfg)).toContain("vless_out");
    expect(cfg.route?.final).toBe("vless_out");
  });

  it("keeps the builtin when a route RULE (not just the default) references it", async () => {
    const { cfg } = await generate(
      `config route_default 'route_default'
\toption action 'route'
\toption outbound 'vless_out'
`,
      `config route_rule 'direct_lan'
\toption enabled '1'
\tlist ip_cidr '192.168.0.0/16'
\toption action 'route'
\toption outbound 'wan'
`,
    );
    expect(tags(cfg)).toContain("wan");
  });

  it("keeps the builtin when a selector group has it as a member", async () => {
    const { cfg } = await generate(
      `config route_default 'route_default'
\toption action 'route'
\toption outbound 'grp'
`,
      `config outbound 'grp'
\toption enabled '1'
\toption type 'selector'
\tlist group_outbounds 'vless_out'
\tlist group_outbounds 'wan'
`,
    );
    expect(tags(cfg)).toContain("wan");
  });

  it("emits bypass as a trailing rule, not as final", async () => {
    const { cfg } = await generate(
      `config route_default 'route_default'
\toption action 'bypass'
\toption outbound 'wan'
`,
    );
    // final is just a tag — it cannot carry an action, so bypass has to be a rule.
    expect(cfg.route?.final).toBeUndefined();
    expect(cfg.route?.rules).toEqual([{ action: "bypass", outbound: "wan" }]);
    expect(tags(cfg)).toContain("wan");
  });

  it("bypass with no outbound emits an empty string and warns about the missing default route", async () => {
    const { cfg, err } = await generate(
      `config route_default 'route_default'
\toption action 'bypass'
`,
    );
    // Documented sing-box behaviour: outside auto-redirect (which this package
    // has no TUN inbound for) an outbound-less bypass rule is SKIPPED — so the
    // user asked for a default route and gets none. Emit it as asked, but say so.
    expect(cfg.route?.rules).toEqual([{ action: "bypass", outbound: "" }]);
    expect(err).toContain("leaving no default route");
    // Nothing references wan any more, so it is pruned here too.
    expect(tags(cfg)).not.toContain("wan");
  });

  it("bypass to a nonexistent outbound degrades to the empty outbound", async () => {
    const { cfg, err } = await generate(
      `config route_default 'route_default'
\toption action 'bypass'
\toption outbound 'ghost'
`,
    );
    expect(cfg.route?.rules).toEqual([{ action: "bypass", outbound: "" }]);
    expect(err).toContain("is not a defined outbound");
  });

  it("cleanup", async () => {
    await exec(`rm -rf ${TMP}`);
  });
});
