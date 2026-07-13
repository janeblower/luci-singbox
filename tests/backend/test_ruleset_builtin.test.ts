import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

// Built-in rule-sets (itdoginfo/allow-domains, `option builtin '1'`, seeded by
// uci-defaults/92-singbox-ui-rulesets) live behind the
// singbox-ui.main.default_rulesets master switch.
//
// Three call sites decide "is this rule-set live" — route.uc's rs_enabled map,
// dns.uc's ruleset_enabled_map, nft-rulesets.uc's fetch loop. They now all route
// through helpers.ruleset_active(), which is what this guards: a gate added to
// one of them only would leave the other two referencing (or downloading) a
// rule-set the UI no longer shows.

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB =
  process.env.SB_VM_LIB ?? `${WORK}/singbox-ui/root/usr/share/singbox-ui/lib`;
const GENERATE_UC = `${WORK}/singbox-ui/root/usr/share/singbox-ui/generate.uc`;
const TMP = `/tmp/sb-builtin-${process.pid}`;
const SANDBOX = `${TMP}/sandbox`;
const OUT = `${SANDBOX}/singbox-ui.json`;

// switch: "1" | "0" | "" (absent — must behave as ON, NO-migration)
function cfg(masterSwitch: string): string {
  const main =
    masterSwitch === ""
      ? "config singbox-ui 'main'\n"
      : `config singbox-ui 'main'\n\toption default_rulesets '${masterSwitch}'\n`;
  return `${main}
config ruleset 'bi'
\toption builtin '1'
\toption enabled '1'
\toption type 'remote'
\toption url 'https://example.com/bi.srs'
\toption nft_rules '1'

config ruleset 'mine'
\toption enabled '1'
\toption type 'remote'
\toption url 'https://example.com/mine.srs'

config outbound 'wan'
\toption enabled '1'
\toption type 'direct'

config route_rule 'r_both'
\toption enabled '1'
\tlist rule_set 'bi'
\tlist rule_set 'mine'
\toption action 'route'
\toption outbound 'wan'

config dns_server 'goog'
\toption enabled '1'
\toption type 'https'
\toption server '8.8.8.8'

config dns_rule 'dr'
\toption enabled '1'
\tlist rule_set 'bi'
\tlist rule_set 'mine'
\toption action 'route'
\toption server 'goog'

config dns 'dns'
\toption final 'goog'
`;
}

async function generate(masterSwitch: string): Promise<Record<string, never>> {
  await exec(`mkdir -p ${SANDBOX}`);
  await putFile(cfg(masterSwitch), `${TMP}/singbox-ui`);
  const r = await exec(
    `cd ${WORK} && UCI_CONFIG_DIR=${TMP} SINGBOX_TMPDIR=${SANDBOX} ` +
      `SINGBOX_CONFIG=${OUT} ucode -L ${LIB} ${GENERATE_UC} 2>${TMP}/err`,
  );
  expect(r.exitCode).toBe(0);
  const body = await exec(`cat ${OUT}`);
  return JSON.parse(body.stdout);
}

interface Cfg {
  // The whole block is omitted when it would carry neither rules nor a final.
  route?: {
    rule_set?: { tag: string }[];
    final?: string;
    // Omitted entirely when every rule was dropped.
    rules?: { rule_set?: string[] }[];
  };
  dns: { rules: { rule_set?: string[] }[] };
}

function ruleSetTags(j: unknown): string[] {
  return ((j as Cfg).route?.rule_set ?? []).map((r) => r.tag).sort();
}

describe("builtin rule-sets honour default_rulesets", () => {
  useGuest();

  it("emits builtin + user sets when the switch is on", async () => {
    const j = (await generate("1")) as unknown as Cfg;
    expect(ruleSetTags(j)).toEqual(["bi", "mine"]);

    const routeRefs = (j.route?.rules ?? []).find((r) => r.rule_set)?.rule_set;
    expect(routeRefs?.sort()).toEqual(["bi", "mine"]);

    const dnsRefs = j.dns.rules.find((r) => r.rule_set)?.rule_set;
    expect(dnsRefs?.sort()).toEqual(["bi", "mine"]);
  });

  it("an absent switch behaves as ON (NO-migration)", async () => {
    const j = (await generate("")) as unknown as Cfg;
    expect(ruleSetTags(j)).toEqual(["bi", "mine"]);
  });

  it("drops builtin sets from route AND dns when the switch is off", async () => {
    const j = (await generate("0")) as unknown as Cfg;
    // The definition is gone — nothing fetches bi.srs any more.
    expect(ruleSetTags(j)).toEqual(["mine"]);

    // Both rule kinds keep their user reference and lose only the builtin one.
    // dns.uc has its OWN ruleset_enabled_map; gating route.uc alone would have
    // left the dns rule pointing at a tag with no route.rule_set definition,
    // which sing-box refuses to start on.
    const routeRefs = (j.route?.rules ?? []).find((r) => r.rule_set)?.rule_set;
    expect(routeRefs).toEqual(["mine"]);

    const dnsRefs = j.dns.rules.find((r) => r.rule_set)?.rule_set;
    expect(dnsRefs).toEqual(["mine"]);
  });

  it("a rule left with ONLY a disabled builtin is dropped, not turned into a catch-all", async () => {
    await exec(`mkdir -p ${SANDBOX}`);
    await putFile(
      `config singbox-ui 'main'
\toption default_rulesets '0'

config ruleset 'bi'
\toption builtin '1'
\toption enabled '1'
\toption type 'remote'
\toption url 'https://example.com/bi.srs'

config outbound 'wan'
\toption enabled '1'
\toption type 'direct'

config route_rule 'r_bionly'
\toption enabled '1'
\tlist rule_set 'bi'
\toption action 'route'
\toption outbound 'wan'

config route_default 'route_default'
\toption action 'route'
\toption outbound 'wan'
`,
      `${TMP}/singbox-ui`,
    );
    const r = await exec(
      `cd ${WORK} && UCI_CONFIG_DIR=${TMP} SINGBOX_TMPDIR=${SANDBOX} ` +
        `SINGBOX_CONFIG=${OUT} ucode -L ${LIB} ${GENERATE_UC} 2>${TMP}/err`,
    );
    expect(r.exitCode).toBe(0);

    const j = JSON.parse((await exec(`cat ${OUT}`)).stdout) as Cfg;
    // A matcher-less rule matches ALL traffic in sing-box, so route.uc must drop
    // the rule outright: no rules at all (the key is omitted when the list comes
    // out empty). Anything surviving here — an empty rule, a bare
    // {action:"route"} — would be a silent catch-all.
    expect(j.route?.rules ?? []).toEqual([]);
    // The final outbound is untouched: only the rule was dropped, not the route.
    expect(j.route?.final).toBe("wan");

    const err = await exec(`cat ${TMP}/err`);
    expect(err.stdout).toContain("lost its only matcher");
  });

  it("nft-rulesets skips a builtin the switch turned off", async () => {
    // The fetch loop used to test `enabled === "0"` on its own, so a disabled
    // builtin kept being downloaded by cron every interval.
    await putFile(cfg("0"), `${TMP}/singbox-ui`);
    const r = await exec(
      `cd ${WORK} && UCI_CONFIG_DIR=${TMP} SINGBOX_TMPDIR=${SANDBOX} ` +
        `ucode -L ${LIB} ${WORK}/singbox-ui/root/usr/share/singbox-ui/nft-rulesets.uc fetch 2>&1 || true`,
    );
    // 'bi' is the only nft_rules=1 set, and it is a disabled builtin.
    expect(r.stdout).toContain("bi disabled, skipping");
  });

  it("cleanup", async () => {
    await exec(`rm -rf ${TMP}`);
  });
});
