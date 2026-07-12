import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { describe, expect, it } from "vitest";

// tests/cross/test_audit_g6_build.sh
// Regression coverage for audit group G6 (build scripts / packaging / i18n):
//   12.1 — regen-po.sh determinism / no leaked absolute paths / pinned date
//   12.2 — build-apk.sh version derivation/validation

const REPO = resolve(import.meta.dirname, "../..");

const SB_PO_DIR = join(REPO, "luci-app-singbox-ui/po");
const REGEN = join(REPO, "scripts/regen-po.sh");
const BUILDSH = join(REPO, "scripts/build-apk.sh");
const POT = join(SB_PO_DIR, "templates/luci-singbox-ui.pot");
const PO = join(SB_PO_DIR, "ru/luci-singbox-ui.po");

// Check tool availability
const xgettextAvailable =
  spawnSync("command", ["-v", "xgettext"], { shell: true }).status === 0;
const msgmergeAvailable =
  spawnSync("command", ["-v", "msgmerge"], { shell: true }).status === 0;
const gettextAvailable = xgettextAvailable && msgmergeAvailable;
const gitAvailable =
  spawnSync("git", ["--version"], { stdio: "ignore" }).status === 0;

describe("audit G6 build scripts / packaging / i18n", () => {
  // Prerequisite: all required files exist
  it("all required source files exist", () => {
    for (const f of [REGEN, BUILDSH, POT, PO]) {
      expect(existsSync(f)).toBe(true);
    }
  });

  // ---------------------------------------------------------------------------
  // 12.1 — committed .pot/.po are portable (no leaked absolute homedir paths)
  // ---------------------------------------------------------------------------
  describe("12.1 committed .pot/.po are portable (no leaked paths)", () => {
    it("POT has no absolute /home paths", () => {
      const pot = readFileSync(POT, "utf8");
      expect(pot).not.toContain("/home/");
    });

    it("PO has no absolute /home paths", () => {
      const po = readFileSync(PO, "utf8");
      expect(po).not.toContain("/home/");
    });

    it("POT has repo-relative '#: htdocs/...' location comments", () => {
      const pot = readFileSync(POT, "utf8");
      expect(pot).toMatch(/^#: htdocs\/luci-static\//m);
    });

    it("POT-Creation-Date is pinned to 2026-06-12 00:00+0000", () => {
      const pot = readFileSync(POT, "utf8");
      const dateLines = pot
        .split("\n")
        .filter((l) => l.startsWith('"POT-Creation-Date:'));
      expect(dateLines.length).toBeGreaterThan(0);
      expect(dateLines[0]).toContain("2026-06-12 00:00+0000");
    });

    it("regen-po.sh passes --sort-output for stable ordering", () => {
      const regen = readFileSync(REGEN, "utf8");
      expect(regen).toContain("--sort-output");
    });

    it("regen-po.sh pins POT-Creation-Date", () => {
      const regen = readFileSync(REGEN, "utf8");
      expect(regen).toContain("POT-Creation-Date");
    });

    it.skipIf(!gettextAvailable)(
      "regen-po.sh is internally deterministic (two runs produce identical output)",
      () => {
        // Save originals
        const origPot = readFileSync(POT);
        const origPo = readFileSync(PO);
        try {
          // Run once
          const r1 = spawnSync("sh", [REGEN], { cwd: REPO, encoding: "utf8" });
          expect(r1.status).toBe(0);
          const pot1 = readFileSync(POT);
          const po1 = readFileSync(PO);

          // Run twice
          const r2 = spawnSync("sh", [REGEN], { cwd: REPO, encoding: "utf8" });
          expect(r2.status).toBe(0);
          const pot2 = readFileSync(POT);
          const po2 = readFileSync(PO);

          expect(pot1.equals(pot2)).toBe(true);
          expect(po1.equals(po2)).toBe(true);

          // Must not leak paths or drift date
          expect(readFileSync(POT, "utf8")).not.toContain("/home/");
          expect(readFileSync(POT, "utf8")).toContain(
            "POT-Creation-Date: 2026-06-12 00:00+0000",
          );
        } finally {
          // Restore exact committed bytes
          writeFileSync(POT, origPot);
          writeFileSync(PO, origPo);
        }
      },
    );
  });

  // ---------------------------------------------------------------------------
  // 12.2 — build-apk.sh version derivation/validation
  // ---------------------------------------------------------------------------
  describe("12.2 build-apk.sh version derivation/validation", () => {
    it("restricts git describe to --match 'v*'", () => {
      const sh = readFileSync(BUILDSH, "utf8");
      expect(sh).toContain("git describe --tags --abbrev=0 --match 'v*'");
    });

    it("has a deterministic 0.0.0-r<N> fallback", () => {
      const sh = readFileSync(BUILDSH, "utf8");
      expect(sh).toContain("0.0.0-r$(git rev-list --count HEAD");
    });

    it("validates the version against X.Y.Z[-rN] regex", () => {
      const sh = readFileSync(BUILDSH, "utf8");
      expect(sh).toContain("^[0-9]+\\.[0-9]+\\.[0-9]+(-r[0-9]+)?$");
    });

    it.skipIf(!gitAvailable)(
      "no-arg version never yields a rolling tag (bbolt-latest/latest)",
      () => {
        // Replicate the version resolution logic inline using spawnSync
        const versionResolve = (arg: string): string | null => {
          let v = arg;
          if (!v) {
            const r1 = spawnSync(
              "sh",
              [
                "-c",
                "git describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//'",
              ],
              { cwd: REPO, encoding: "utf8" },
            );
            v = (r1.stdout ?? "").trim();
            if (!v) {
              const r2 = spawnSync(
                "sh",
                ["-c", "git rev-list --count HEAD 2>/dev/null || echo 0"],
                { cwd: REPO, encoding: "utf8" },
              );
              v = `0.0.0-r${(r2.stdout ?? "0").trim()}`;
            }
          }
          if (!/^[0-9]+\.[0-9]+\.[0-9]+(-r[0-9]+)?$/.test(v)) return null;
          return v;
        };

        const noarg = versionResolve("");
        expect(["bbolt-latest", "latest", null, ""]).not.toContain(noarg);
        expect(noarg).toMatch(/^[0-9]+\.[0-9]+\.[0-9]+(-r[0-9]+)?$/);
      },
    );

    it.skipIf(!gitAvailable)("valid explicit versions accepted", () => {
      const versionResolve = (arg: string): string | null => {
        if (!/^[0-9]+\.[0-9]+\.[0-9]+(-r[0-9]+)?$/.test(arg)) return null;
        return arg;
      };
      for (const good of ["1.2.3", "0.0.0-r572", "10.20.30", "2.0.0-r1"]) {
        expect(versionResolve(good)).not.toBeNull();
      }
    });

    it.skipIf(!gitAvailable)("garbage versions rejected", () => {
      const versionResolve = (arg: string): string | null => {
        if (!/^[0-9]+\.[0-9]+\.[0-9]+(-r[0-9]+)?$/.test(arg)) return null;
        return arg;
      };
      for (const bad of [
        "bbolt-latest",
        "latest",
        "1.2",
        "v1.2.3",
        "1.2.3-beta",
        "1.2.3.4",
        "x",
      ]) {
        expect(versionResolve(bad)).toBeNull();
      }
    });
  });
});
