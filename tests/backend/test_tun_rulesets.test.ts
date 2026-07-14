import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

// A tun inbound's route_address_set / route_exclude_address_set name OUR rule-set
// sections, and sing-box resolves those tags ITSELF. A tag with no matching
// route.rule_set definition does not degrade — it kills the whole config:
//
//   initialize inbound[0]: parse route_address_set: rule-set not found: ru_block
//
// Rule-sets used to be emitted only when a route rule or a dns rule referenced
// one, so a tun-only reference produced exactly that. (The tproxy path never
// needed a definition: it reads rs_*.json behind sing-box's back.)
//
// The invariant, and the reason the last test here exists: whatever condition
// makes tun.uc EMIT a route_*_address_set key must be the same condition under
// which generate.uc DEFINES those rule-sets. inbound.referenced_rulesets() is fed
// the BUILT inbounds so the two are the same condition by construction — this
// file pins that end to end, through the prod argv path and the real core.

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB = `${WORK}/singbox-ui/root/usr/share/singbox-ui/lib`;
const GENERATE_UC = `${WORK}/singbox-ui/root/usr/share/singbox-ui/generate.uc`;

type Gen = {
  rc: number;
  stderr: string;
  doc: any;
  check: string;
  checkRc: number;
};

// Generate exactly as init.d/rpcd do (argv + env), then hand the result to the
// REAL core. A green assertion on a config sing-box never saw is precisely how
// the dangling-tag bug survived: both halves looked fine on their own.
async function generate(uciBody: string): Promise<Gen> {
  const dir = `/tmp/tunrs_${process.pid}_${Math.random().toString(36).slice(2)}`;
  const out = `${dir}/singbox-ui.json`;
  await exec(`mkdir -p ${dir}/subs`);
  await putFile(uciBody, `${dir}/singbox-ui`);

  const r = await exec(
    `cd ${WORK} && UCI_CONFIG_DIR=${dir} SINGBOX_TMPDIR=${dir}/subs SINGBOX_CONFIG=${out} ` +
      `ucode -L ${LIB} ${GENERATE_UC} >/dev/null; echo "RC=$?"; ` +
      `sing-box check -c ${out} 2>&1; echo "CHECK=$?"; ` +
      `echo '--CFG--'; cat ${out}; rm -rf ${dir}`,
  );
  const rc = Number(r.stdout.match(/RC=(\d+)/)?.[1] ?? -1);
  const checkRc = Number(r.stdout.match(/CHECK=(\d+)/)?.[1] ?? -1);
  const body = r.stdout.split("--CFG--\n")[1] ?? "";
  const check = r.stdout.replace(/[\s\S]*?RC=\d+\n/, "").split(/CHECK=\d+/)[0];
  return {
    rc,
    stderr: r.stderr,
    doc: body ? JSON.parse(body) : null,
    check,
    checkRc,
  };
}

const RULESET = (name: string, extra = "") => `
config ruleset '${name}'
\toption enabled '1'
\toption type 'remote'
\toption url 'https://example.com/${name}.srs'
${extra}`;

// A tun that references a rule-set and NOTHING else does — no route rule, no dns
// rule. auto_route is what gates the *_address_set keys (auto_redirect does NOT:
// since 1.11 the sets go to the routes instead of the firewall without it, and a
// live check accepts that), so it is spelled out per case.
const TUN = (
  autoRoute: string | null,
  key: string,
  ref: string,
  extra = "",
) => `
config inbound 'tun_in'
\toption enabled '1'
\toption protocol 'tun'
\tlist address '172.19.0.1/30'
${autoRoute === null ? "" : `\toption auto_route '${autoRoute}'\n`}\tlist ${key} '${ref}'
${extra}`;

function ruleSetTags(doc: any): string[] {
  return (doc?.route?.rule_set ?? []).map((r: any) => r.tag);
}

describe("tun rule-set references (route_address_set / route_exclude_address_set)", () => {
  useGuest();

  it("a rule-set referenced ONLY by tun.route_address_set is DEFINED in route.rule_set", async () => {
    const g = await generate(
      RULESET("ru_block") + TUN("1", "route_address_set", "ru_block"),
    );
    expect(g.rc).toBe(0);
    expect(g.doc.inbounds[0].route_address_set).toEqual(["ru_block"]);
    // RED before the fix: [] — no route rule and no dns rule referenced it, so
    // nothing defined it, and the tag dangled.
    expect(ruleSetTags(g.doc)).toEqual(["ru_block"]);
    // And the core agrees. RED before the fix:
    //   FATAL initialize inbound[0]: parse route_address_set: rule-set not found: ru_block
    expect(g.check).not.toContain("rule-set not found");
    expect(g.checkRc).toBe(0);
  });

  it("route_exclude_address_set is defined too", async () => {
    const g = await generate(
      RULESET("ru_bypass") + TUN("1", "route_exclude_address_set", "ru_bypass"),
    );
    expect(g.doc.inbounds[0].route_exclude_address_set).toEqual(["ru_bypass"]);
    expect(ruleSetTags(g.doc)).toEqual(["ru_bypass"]);
    expect(g.checkRc).toBe(0);
  });

  // POLARITY. tun.auto_route has `default: 0` — LuCI deletes an option equal to
  // its default, so UNSET MEANS OFF and the only correct test is `=== "1"`.
  // (tproxy.nft_rules is the mirror image: default 1, never emitted, so `!== "0"`
  // is right for IT. Copying that polarity over is the mistake this guards.)
  // Unset ⇒ the `requires` gate suppresses route_address_set ⇒ nothing to define.
  // Flip the condition to `!== "0"` and the rule-set gets defined (and fetched in
  // the background, forever) for an inbound that never references it.
  for (const autoRoute of [null, "0"]) {
    it(`auto_route ${autoRoute === null ? "unset" : "'0'"}: contributes NO rule-set`, async () => {
      const g = await generate(
        RULESET("ru_block") + TUN(autoRoute, "route_address_set", "ru_block"),
      );
      expect(g.rc).toBe(0);
      expect(g.doc.inbounds[0].route_address_set).toBeUndefined();
      expect(ruleSetTags(g.doc)).toEqual([]);
      expect(g.checkRc).toBe(0);
    });
  }

  it("an INACTIVE rule-set is pruned from the built object — no dangling tag, no empty array", async () => {
    const g = await generate(
      RULESET("ru_block").replace("option enabled '1'", "option enabled '0'") +
        TUN("1", "route_address_set", "ru_block"),
    );
    expect(g.rc).toBe(0);
    // The descriptor emits whatever UCI holds; the prune is what stops a user
    // disabling a rule-set from taking the daemon down with a dangling tag.
    expect("route_address_set" in g.doc.inbounds[0]).toBe(false); // NOT [] — absent
    expect(ruleSetTags(g.doc)).toEqual([]);
    expect(g.stderr).toContain("is not active");
    expect(g.checkRc).toBe(0);
  });

  it("a builtin rule-set switched off by the master flag is pruned too", async () => {
    // helpers.ruleset_active is the ONE predicate: `enabled` alone would keep
    // this one, since the builtin is enabled — main.default_rulesets is what
    // turns it off, and the UI stops showing it.
    const uci =
      "\nconfig main 'main'\n\toption default_rulesets '0'\n" +
      RULESET("ru_builtin", "\toption builtin '1'\n") +
      TUN("1", "route_address_set", "ru_builtin");
    const g = await generate(uci);
    expect("route_address_set" in g.doc.inbounds[0]).toBe(false);
    expect(ruleSetTags(g.doc)).toEqual([]);
    expect(g.checkRc).toBe(0);
  });

  it("hijack_dns on a tun emits the hijack-dns route rule, as it does for tproxy", async () => {
    const g = await generate(`
config inbound 'tun_in'
\toption enabled '1'
\toption protocol 'tun'
\tlist address '172.19.0.1/30'
\toption auto_route '1'
\toption hijack_dns '1'
`);
    expect(g.rc).toBe(0);
    expect(g.doc.route.rules).toContainEqual({
      protocol: "dns",
      action: "hijack-dns",
    });
    expect(g.checkRc).toBe(0);
  });

  // THE anti-drift guard. Emission (tun.uc's `requires`) and definition
  // (generate.uc's union) are two different files; if they ever disagree the core
  // refuses the config outright. Rather than restate the condition a third time
  // here, assert the invariant itself over a matrix that straddles the gate: every
  // tag the config EMITS is a tag the config DEFINES. It holds whichever way a
  // future edit moves the gate — and fails the moment the two stop agreeing.
  it("every emitted tun rule-set tag has a route.rule_set definition (matrix)", async () => {
    const cases = [
      RULESET("a") + TUN("1", "route_address_set", "a"),
      RULESET("a") + TUN("0", "route_address_set", "a"),
      RULESET("a") + TUN(null, "route_address_set", "a"),
      RULESET("a") +
        TUN("1", "route_address_set", "a", "\toption auto_redirect '1'\n"),
      RULESET("a") +
        TUN("0", "route_address_set", "a", "\toption auto_redirect '1'\n"),
      RULESET("a") +
        RULESET("b") +
        TUN(
          "1",
          "route_address_set",
          "a",
          "\tlist route_exclude_address_set 'b'\n",
        ),
      // Referenced by a route rule as well: the union must dedupe, not double up.
      RULESET("a") +
        TUN("1", "route_address_set", "a") +
        "\nconfig route_rule 'r'\n\toption enabled '1'\n\tlist rule_set 'a'\n\toption action 'reject'\n",
    ];
    for (const uci of cases) {
      const g = await generate(uci);
      expect(g.rc).toBe(0);
      const defined = ruleSetTags(g.doc);
      expect(defined.length).toBe(new Set(defined).size); // deduped
      const emitted = [
        ...(g.doc.inbounds[0].route_address_set ?? []),
        ...(g.doc.inbounds[0].route_exclude_address_set ?? []),
      ];
      for (const tag of emitted) expect(defined).toContain(tag);
      expect(g.checkRc).toBe(0); // the core is the final arbiter
    }
  });
});
