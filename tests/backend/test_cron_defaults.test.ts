import { describe, expect, it } from "bun:test";
import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

// Port of tests/backend/test_cron_defaults.sh
// Host-only: reads repo files via fs, runs the shell script under 'sh'.
// No guest connection needed.

const REPO = path.resolve(import.meta.dir, "../..");
const SB_BACKEND_ROOT = "singbox-ui/root";
const SCRIPT = path.join(
  REPO,
  SB_BACKEND_ROOT,
  "etc/uci-defaults/91-singbox-ui-cron",
);
const NINETYNINE = path.join(
  REPO,
  SB_BACKEND_ROOT,
  "etc/uci-defaults/99-luci-singbox-ui",
);

describe("cron_defaults (91-singbox-ui-cron idempotency + 99 owns no cron)", () => {
  it("91-singbox-ui-cron script exists", () => {
    expect(fs.existsSync(SCRIPT)).toBe(true);
  });

  it("99-luci-singbox-ui does NOT touch crontab (no cron block)", () => {
    expect(fs.existsSync(NINETYNINE)).toBe(true);
    const content = fs.readFileSync(NINETYNINE, "utf8");
    // Must not contain any crontab manipulation keywords
    expect(content).not.toMatch(/crontab|CRON_LINE|CRON_FILE/);
  });

  it("91 installs exactly 1 subscription.uc line + 1 nft-rulesets.uc line; migrates legacy; idempotent", () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "sb-cron-test-"));
    try {
      const cronDir = path.join(tmp, "crontabs");
      fs.mkdirSync(cronDir, { recursive: true });
      const cronFile = path.join(cronDir, "root");

      // Seed BOTH legacy forms (old 91 subs-only + old 99 combined)
      fs.writeFileSync(
        cronFile,
        `0 0 * * * /bin/true
*/15 * * * * /usr/bin/ucode -L /usr/share/singbox-ui/lib /usr/share/singbox-ui/subscription.uc refresh subscriptions
*/30 * * * * /usr/bin/ucode -L /usr/share/singbox-ui/lib /usr/share/singbox-ui/subscription.uc refresh all >/dev/null 2>&1
`,
      );

      const runOnce = () =>
        spawnSync("sh", [SCRIPT], {
          env: {
            ...process.env,
            SINGBOX_CRONTAB: cronFile,
            SINGBOX_CRON_RELOAD: "true",
          },
          encoding: "utf8",
        });

      // Run twice — idempotent
      const r1 = runOnce();
      expect(r1.status).toBe(0);
      const r2 = runOnce();
      expect(r2.status).toBe(0);

      const result = fs.readFileSync(cronFile, "utf8");

      // Legacy lines must be gone
      const legacy = (result.match(/refresh subscriptions|refresh all/g) ?? [])
        .length;
      expect(legacy).toBe(0);

      // Exactly 1 subscription.uc refresh line (no trailing arg)
      const subLines = (result.match(/subscription\.uc refresh$/gm) ?? [])
        .length;
      expect(subLines).toBe(1);

      // Exactly 1 nft-rulesets.uc refresh line (no trailing arg)
      const rsLines = (result.match(/nft-rulesets\.uc refresh$/gm) ?? [])
        .length;
      expect(rsLines).toBe(1);

      // Unrelated line preserved
      const unrelated = (result.match(/\/bin\/true/g) ?? []).length;
      expect(unrelated).toBe(1);
    } finally {
      fs.rmSync(tmp, { recursive: true, force: true });
    }
  });
});
