import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec } from "../helpers/ssh.ts";

// uci-defaults/92-singbox-ui-rulesets is what actually PUTS the 25 built-in
// rule-sets on the router. Everything else (helpers.ruleset_active, the locked
// grid rows, the master switch) was already guarded — the seeding itself was not,
// which is exactly the gap that lets a user upgrade and see no rule-sets at all.
//
// Needs a real `uci`, so it runs in the guest. The uci CLI does NOT honour
// UCI_CONFIG_DIR (only `-c <dir>`), which is why the script takes a SINGBOX_UCI
// seam — without it this could only be tested against the live /etc/config.

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const SCRIPT = `${WORK}/singbox-ui/root/etc/uci-defaults/92-singbox-ui-rulesets`;
const SEED = `${WORK}/singbox-ui/root/etc/config/singbox-ui`;

const ALL_SETS = [
  "anime",
  "block",
  "cloudflare",
  "cloudfront",
  "digitalocean",
  "discord",
  "geoblock",
  "google_ai",
  "google_meet",
  "google_play",
  "hdrezka",
  "hetzner",
  "hodca",
  "meta",
  "news",
  "ovh",
  "porn",
  "roblox",
  "russia_inside",
  "russia_outside",
  "telegram",
  "tiktok",
  "twitter",
  "ukraine_inside",
  "youtube",
];

// A fresh sandbox seeded with the SHIPPED config, then the script run against it
// exactly as a package install would.
async function seed(dir: string, mutate = ""): Promise<void> {
  await exec(`
    rm -rf ${dir} && mkdir -p ${dir}
    cp ${SEED} ${dir}/singbox-ui
    ${mutate}
  `);
}

async function runScript(dir: string): Promise<number> {
  const r = await exec(
    `SINGBOX_UCI="uci -c ${dir}" sh ${SCRIPT}; echo "rc=$?"`,
  );
  const m = r.stdout.match(/rc=(\d+)/);
  return m ? Number(m[1]) : -1;
}

// name -> { builtin, enabled, type, url, ... }
async function rulesets(dir: string): Promise<Record<string, string>> {
  const r = await exec(
    `uci -c ${dir} show singbox-ui | grep -E '^singbox-ui\\.'`,
  );
  const out: Record<string, string> = {};
  for (const line of r.stdout.split("\n")) {
    const m = line.match(/^singbox-ui\.([^.=]+)(?:\.([^=]+))?=(.*)$/);
    if (!m) continue;
    const [, sec, opt, val] = m;
    out[opt ? `${sec}.${opt}` : sec] = val.replace(/^'|'$/g, "");
  }
  return out;
}

describe("92-singbox-ui-rulesets seeds the built-in rule-sets", () => {
  useGuest();

  const DIR = `/tmp/sb-seed-${process.pid}`;

  it("creates all 25, all marked builtin", async () => {
    await seed(DIR);
    expect(await runScript(DIR)).toBe(0);
    const u = await rulesets(DIR);

    const found = ALL_SETS.filter((n) => u[n] === "ruleset");
    expect(found.sort()).toEqual([...ALL_SETS].sort());
    for (const n of ALL_SETS) expect(u[`${n}.builtin`]).toBe("1");
  });

  it("only the two the seed config actually references ship enabled", async () => {
    const u = await rulesets(DIR);
    // Nothing is downloaded until a rule references the set, so the other 23 are
    // inert — shipping them all enabled would put 25 .srs fetches on a fresh box.
    const enabled = ALL_SETS.filter((n) => u[`${n}.enabled`] !== "0");
    expect(enabled.sort()).toEqual(["discord", "russia_inside"]);
  });

  it("points every URL at the allow-domains latest-release alias", async () => {
    const u = await rulesets(DIR);
    for (const n of ALL_SETS) {
      expect(u[`${n}.type`]).toBe("remote");
      expect(u[`${n}.url`]).toBe(
        `https://github.com/itdoginfo/allow-domains/releases/latest/download/${n}.srs`,
      );
    }
  });

  it("is idempotent, and an upgrade never flips a set the user turned on back off", async () => {
    // A package upgrade re-runs uci-defaults. If it reset `enabled`, everyone who
    // had switched `porn` or `youtube` on would silently lose it.
    await exec(
      `uci -c ${DIR} set singbox-ui.porn.enabled=1 && uci -c ${DIR} commit singbox-ui`,
    );
    expect(await runScript(DIR)).toBe(0);

    const u = await rulesets(DIR);
    expect(u["porn.enabled"]).toBe("1");
    expect(ALL_SETS.filter((n) => u[n] === "ruleset").length).toBe(25);
  });

  it("creates nothing at all when the master switch is off", async () => {
    const OFF = `${DIR}-off`;
    await seed(
      OFF,
      `sed -i "s/option default_rulesets '1'/option default_rulesets '0'/" ${OFF}/singbox-ui`,
    );
    expect(await runScript(OFF)).toBe(0);

    const u = await rulesets(OFF);
    // The two from the shipped config are still there (the script did not touch
    // them), but none of the other 23 were created.
    const created = ALL_SETS.filter(
      (n) => u[n] === "ruleset" && n !== "russia_inside" && n !== "discord",
    );
    expect(created).toEqual([]);
    await exec(`rm -rf ${OFF}`);
  });

  it("cleanup", async () => {
    await exec(`rm -rf ${DIR}`);
  });
});
