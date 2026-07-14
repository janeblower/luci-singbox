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

  it("ships every one of them ENABLED", async () => {
    const u = await rulesets(DIR);
    const disabled = ALL_SETS.filter((n) => u[`${n}.enabled`] === "0");
    expect(disabled).toEqual([]);
  });

  it("an enabled-but-unreferenced set costs nothing, which is why they all ship on", async () => {
    // The reason this is safe, asserted rather than assumed: a rule-set nobody
    // references is neither emitted into the config (ruleset.uc only builds the
    // referenced tags) nor downloaded (nft-rulesets.uc only fetches nft_rules=1).
    const u = await rulesets(DIR);
    for (const n of ALL_SETS) {
      if (n === "discord") continue; // the seed's nft example
      expect(u[`${n}.nft_rules`]).toBe("0");
    }
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

  it("is idempotent, and an upgrade never re-enables a set the user turned OFF", async () => {
    // A package upgrade re-runs uci-defaults. Now that everything ships enabled,
    // the direction that matters is the other one: someone who deliberately
    // switched `porn` off must not have it silently switched back on.
    await exec(
      `uci -c ${DIR} set singbox-ui.porn.enabled=0 && uci -c ${DIR} commit singbox-ui`,
    );
    expect(await runScript(DIR)).toBe(0);

    const u = await rulesets(DIR);
    expect(u["porn.enabled"]).toBe("0");
    expect(ALL_SETS.filter((n) => u[n] === "ruleset").length).toBe(25);
  });

  it("a second run changes nothing and does not rewrite the config (wear-safe)", async () => {
    // start_service calls the seed on EVERY boot to self-heal a wiped config, so
    // a no-op run must not churn /etc/config (flash wear on real routers). The
    // seed only commits when something actually changed — even a same-content
    // `uci commit` rewrites the file and bumps mtime, so mtime is the real signal.
    const mtime = async () =>
      (await exec(`date -r ${DIR}/singbox-ui +%s`)).stdout.trim();
    const contents = async () => (await exec(`cat ${DIR}/singbox-ui`)).stdout;
    const [mBefore, cBefore] = [await mtime(), await contents()];
    await exec("sleep 1"); // ensure a rewrite would show a DIFFERENT mtime
    expect(await runScript(DIR)).toBe(0);
    expect(await mtime()).toBe(mBefore); // the commit never fired
    expect(await contents()).toBe(cBefore);
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
