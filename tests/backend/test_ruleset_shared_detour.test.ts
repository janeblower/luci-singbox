import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

// main.default_ruleset_detour — ONE shared download detour for every built-in
// rule-set. They all fetch from the same github release, so this is the "github
// is blocked, pull them through a proxy" knob (one selector, not 25 rows).
//
// It applies ONLY to a BUILTIN REMOTE set that has no download_detour of its
// own; a user's own set, or a builtin the operator gave a specific detour, is
// left alone. A dangling detour is dropped by the existing outbound check.

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB =
  process.env.SB_VM_LIB ?? `${WORK}/singbox-ui/root/usr/share/singbox-ui/lib`;
const GENERATE_UC = `${WORK}/singbox-ui/root/usr/share/singbox-ui/generate.uc`;
const TMP = `/tmp/sb-rsdetour-${process.pid}`;
const SANDBOX = `${TMP}/sandbox`;
const OUT = `${SANDBOX}/singbox-ui.json`;

interface RuleSet {
  tag: string;
  type: string;
  download_detour?: string;
}
interface Cfg {
  route?: { rule_set?: RuleSet[] };
}

// bi = builtin remote, biOwn = builtin remote WITH its own detour, mine = user
// remote. A route rule references all three so they are all emitted. `warp` and
// `proxy` are defined outbounds; `detour` is the shared value under test.
function cfg(detour: string | null): string {
  const main =
    detour === null
      ? "config singbox-ui 'main'\n"
      : `config singbox-ui 'main'\n\toption default_ruleset_detour '${detour}'\n`;
  return `${main}
config outbound 'warp'
\toption enabled '1'
\toption type 'direct'

config outbound 'proxy'
\toption enabled '1'
\toption type 'direct'

config ruleset 'bi'
\toption builtin '1'
\toption enabled '1'
\toption type 'remote'
\toption url 'https://example.com/bi.srs'

config ruleset 'biOwn'
\toption builtin '1'
\toption enabled '1'
\toption type 'remote'
\toption url 'https://example.com/biOwn.srs'
\toption download_detour 'proxy'

config ruleset 'mine'
\toption enabled '1'
\toption type 'remote'
\toption url 'https://example.com/mine.srs'

config route_rule 'r'
\toption enabled '1'
\tlist rule_set 'bi'
\tlist rule_set 'biOwn'
\tlist rule_set 'mine'
\toption action 'route'
\toption outbound 'warp'
`;
}

async function generate(detour: string | null): Promise<Cfg> {
  await exec(`mkdir -p ${SANDBOX}`);
  await putFile(cfg(detour), `${TMP}/singbox-ui`);
  const r = await exec(
    `cd ${WORK} && UCI_CONFIG_DIR=${TMP} SINGBOX_TMPDIR=${SANDBOX} ` +
      `SINGBOX_CONFIG=${OUT} ucode -L ${LIB} ${GENERATE_UC} 2>${TMP}/err`,
  );
  expect(r.exitCode).toBe(0);
  const body = await exec(`cat ${OUT}`);
  return JSON.parse(body.stdout) as Cfg;
}

function detourOf(cfg: Cfg, tag: string): string | undefined {
  return (cfg.route?.rule_set ?? []).find((r) => r.tag === tag)
    ?.download_detour;
}

describe("shared built-in rule-set download detour", () => {
  useGuest();

  it("applies the shared detour to a builtin remote set with no detour of its own", async () => {
    const j = await generate("warp");
    expect(detourOf(j, "bi")).toBe("warp");
  });

  it("never overrides a builtin's own download_detour", async () => {
    const j = await generate("warp");
    expect(detourOf(j, "biOwn")).toBe("proxy");
  });

  it("never touches a user (non-builtin) set", async () => {
    const j = await generate("warp");
    expect(detourOf(j, "mine")).toBeUndefined();
  });

  it("no shared detour set → builtins fetch directly", async () => {
    const j = await generate(null);
    expect(detourOf(j, "bi")).toBeUndefined();
    expect(detourOf(j, "biOwn")).toBe("proxy"); // its own is still honoured
  });

  it("a dangling shared detour is dropped (existing outbound check), config still valid", async () => {
    const j = await generate("ghost");
    expect(detourOf(j, "bi")).toBeUndefined();
    const err = (await exec(`cat ${TMP}/err`)).stdout;
    expect(err).toContain("is not a defined outbound");
  });

  it("cleanup", async () => {
    await exec(`rm -rf ${TMP}`);
  });
});
