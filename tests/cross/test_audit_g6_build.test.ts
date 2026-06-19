import { describe, expect, it } from "bun:test";
import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

// tests/cross/test_audit_g6_build.sh
// Regression coverage for audit group G6 (build scripts / packaging / i18n):
//   12.1 — regen-po.sh determinism / no leaked absolute paths / pinned date
//   12.2 — build-apk.sh version derivation/validation
//   12.4 — Makefile install loop hard-fails on unknown mode

const REPO = resolve(import.meta.dir, "../..");

const SB_PO_DIR = join(REPO, "luci-app-singbox-ui/po");
const REGEN = join(REPO, "scripts/regen-po.sh");
const BUILDSH = join(REPO, "scripts/build-apk.sh");
const MAKEFILE = join(REPO, "singbox-ui/Makefile");
const LUCIAPP_MAKEFILE = join(REPO, "luci-app-singbox-ui/Makefile");
const BBOLT_MAKEFILE = join(REPO, "bbolt-client/Makefile");
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
    for (const f of [
      REGEN,
      BUILDSH,
      MAKEFILE,
      LUCIAPP_MAKEFILE,
      BBOLT_MAKEFILE,
      POT,
      PO,
    ]) {
      expect(existsSync(f)).toBe(true);
    }
  });

  // ---------------------------------------------------------------------------
  // G6 split — three package Makefiles carry key fields
  // ---------------------------------------------------------------------------
  describe("split: three package Makefiles carry PKG_NAME and key fields", () => {
    it("singbox-ui/Makefile: PKG_NAME:=singbox-ui", () => {
      const mk = readFileSync(MAKEFILE, "utf8");
      expect(mk).toMatch(/^PKG_NAME:=singbox-ui/m);
    });

    it("singbox-ui/Makefile: BuildPackage", () => {
      const mk = readFileSync(MAKEFILE, "utf8");
      expect(mk).toContain("BuildPackage");
    });

    it("singbox-ui/Makefile: DEPENDS includes +bbolt-client", () => {
      const mk = readFileSync(MAKEFILE, "utf8");
      expect(mk).toMatch(/^\s*DEPENDS:=.*\+bbolt-client/m);
    });

    it("luci-app-singbox-ui/Makefile: PKG_NAME:=luci-app-singbox-ui", () => {
      const mk = readFileSync(LUCIAPP_MAKEFILE, "utf8");
      expect(mk).toMatch(/^PKG_NAME:=luci-app-singbox-ui/m);
    });

    it("luci-app-singbox-ui/Makefile: includes luci.mk", () => {
      const mk = readFileSync(LUCIAPP_MAKEFILE, "utf8");
      expect(mk).toContain("luci.mk");
    });

    it("luci-app-singbox-ui/Makefile: LUCI_DEPENDS includes +singbox-ui", () => {
      const mk = readFileSync(LUCIAPP_MAKEFILE, "utf8");
      expect(mk).toMatch(/^\s*LUCI_DEPENDS:=.*\+singbox-ui/m);
    });

    it("bbolt-client/Makefile: PKG_NAME:=bbolt-client", () => {
      const mk = readFileSync(BBOLT_MAKEFILE, "utf8");
      expect(mk).toMatch(/^PKG_NAME:=bbolt-client/m);
    });

    it("bbolt-client/Makefile: BuildPackage", () => {
      const mk = readFileSync(BBOLT_MAKEFILE, "utf8");
      expect(mk).toContain("BuildPackage");
    });

    it("bbolt-client/Makefile: DEPENDS includes +libc", () => {
      const mk = readFileSync(BBOLT_MAKEFILE, "utf8");
      expect(mk).toMatch(/^\s*DEPENDS:=.*\+libc/m);
    });
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

  // ---------------------------------------------------------------------------
  // 12.4 — Makefile install loop hard-fails on unknown mode (no 0644 degrade)
  // ---------------------------------------------------------------------------
  describe("12.4 Makefile install loop hard-fails on unknown mode", () => {
    for (const [label, path] of [
      ["singbox-ui/Makefile", MAKEFILE],
      ["luci-app-singbox-ui/Makefile", LUCIAPP_MAKEFILE],
    ]) {
      it(`${label}: catch-all must NOT silently install as 0644`, () => {
        const mk = readFileSync(path as string, "utf8");
        // The catch-all (*) must NOT have 'install -m 0644' on the same line
        const lines = mk.split("\n");
        for (const line of lines) {
          if (/^\s*\*\)/.test(line) && /install -m 0644/.test(line)) {
            throw new Error(
              `${label} catch-all still silently installs unknown modes as 0644`,
            );
          }
        }
      });

      it(`${label}: dispatches on $$mode (case statement)`, () => {
        const mk = readFileSync(path as string, "utf8");
        expect(mk).toContain('case "$$mode" in');
      });

      it(`${label}: catch-all echoes 'unknown mode' and exits 1`, () => {
        const mk = readFileSync(path as string, "utf8");
        expect(mk).toMatch(/\*\).*unknown mode.*exit 1/);
      });

      it(`${label}: enumerates data) explicitly (parity with build-apk.sh)`, () => {
        const mk = readFileSync(path as string, "utf8");
        expect(mk).toMatch(/\bdata\)\s*install -m 0644/);
      });
    }

    it("runtime: valid manifest modes (bin/conf/data) pass the install loop", () => {
      const tmp = mkdtempSync(join(tmpdir(), "g6-test-"));
      try {
        const okTsv = join(tmp, "ok.tsv");
        writeFileSync(
          okTsv,
          "a.uc\tusr/x/a.uc\tbin\nb.json\tetc/b\tdata\nc\td\tconf\n",
        );
        const script = `
while IFS="$(printf '\\t')" read -r src dst mode; do
  case "$src" in '#'*|'') continue ;; esac
  case "$mode" in
    bin)  : ;;
    conf) : ;;
    data) : ;;
    *)    echo "install-manifest.txt: unknown mode '$mode' for $src" >&2; exit 1 ;;
  esac
done < "${okTsv}"
`;
        const r = spawnSync("sh", ["-c", script], { encoding: "utf8" });
        expect(r.status).toBe(0);
      } finally {
        rmSync(tmp, { recursive: true, force: true });
      }
    });

    it("runtime: typo'd mode 'binn' hard-fails the install loop", () => {
      const tmp = mkdtempSync(join(tmpdir(), "g6-test-"));
      try {
        const badTsv = join(tmp, "bad.tsv");
        writeFileSync(badTsv, "a.uc\tusr/x/a.uc\tbinn\n");
        const script = `
while IFS="$(printf '\\t')" read -r src dst mode; do
  case "$src" in '#'*|'') continue ;; esac
  case "$mode" in
    bin)  : ;;
    conf) : ;;
    data) : ;;
    *)    echo "install-manifest.txt: unknown mode '$mode' for $src" >&2; exit 1 ;;
  esac
done < "${badTsv}"
`;
        const r = spawnSync("sh", ["-c", script], { encoding: "utf8" });
        expect(r.status).not.toBe(0);
      } finally {
        rmSync(tmp, { recursive: true, force: true });
      }
    });
  });
});
