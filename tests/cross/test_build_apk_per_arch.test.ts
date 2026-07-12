/**
 * tests/cross/test_build_apk_per_arch.test.ts
 *
 * Asserts scripts/build-apk.sh produces the FOUR-package noarch split:
 *   - singbox-ui_<ver>.apk                     noarch backend (bundles the
 *     pure-ucode bbolt cache.db reader as a module: lib/bbolt.uc, required
 *     in-process — no CLI shim ships)
 *   - luci-app-singbox-ui_<ver>.apk            noarch LuCI frontend
 *   - luci-i18n-singbox-ui-ru_<ver>.apk        noarch Russian translation
 *   - singbox-ui-plugin-awg_warp_<ver>.apk     noarch AWG-WARP plugin
 *
 * The former per-arch Rust bbolt-client package (20 apks) is gone: the reader is
 * now ucode shipped inside singbox-ui, so there is no per-arch matrix.
 *
 * Driven via APK_MKPKG_STUB=1 (no SDK needed). SKIPs if bash is unavailable
 * (e.g. OpenWrt qemu guest has only BusyBox ash).
 */

import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { describe, expect, it } from "vitest";

const ROOT = resolve(import.meta.dirname, "../..");
const BUILDSH = resolve(ROOT, "scripts/build-apk.sh");

// Skip guard: build-apk.sh is bash-only; reproduce the exact shell guard.
const bashCheck = spawnSync("bash", ["--version"], { encoding: "utf8" });
const hasBash = bashCheck.status === 0 && !bashCheck.error;

// Lazily-built output (only when bash is available)
type BuildResult = {
  out: string;
  work: string;
};

let buildResult: BuildResult | null = null;
let buildError: string | null = null;

function ensureBuild(): BuildResult {
  if (buildResult) return buildResult;
  if (buildError) throw new Error(buildError);

  const work = mkdtempSync(resolve(tmpdir(), "apk-noarch-"));
  const out = resolve(work, "dist");

  const result = spawnSync("bash", [BUILDSH, "0.0.0-r1", out], {
    cwd: ROOT,
    encoding: "utf8",
    env: {
      ...process.env,
      APK_MKPKG_STUB: "1",
      WORK_DIR: resolve(work, ".build"),
    },
  });

  if (result.status !== 0) {
    buildError = `build-apk.sh failed:\n${result.stderr}`;
    rmSync(work, { recursive: true, force: true });
    throw new Error(buildError);
  }

  buildResult = { out, work };
  return buildResult;
}

describe("build_apk_noarch", () => {
  it.skipIf(!hasBash)("four noarch packages: exactly one each", () => {
    const { out } = ensureBuild();
    for (const name of [
      "singbox-ui",
      "luci-app-singbox-ui",
      "luci-i18n-singbox-ui-ru",
      "singbox-ui-plugin-awg_warp",
    ]) {
      const apks = readdirSync(out).filter((f) => f === `${name}_0.0.0-r1.apk`);
      expect(apks.length).toBe(1);
    }
  });

  it.skipIf(!hasBash)("total apk count is exactly 4 (all noarch)", () => {
    const { out } = ensureBuild();
    const total = readdirSync(out).filter((f) => f.endsWith(".apk")).length;
    expect(total).toBe(4);
  });

  it.skipIf(!hasBash)(
    "singbox-ui backend root bundles lib/bbolt.uc and NOT a forked CLI shim",
    () => {
      const { work } = ensureBuild();
      const root = resolve(work, ".build/pkg-root-singbox-ui");
      // The reader is a module the backend requires in-process. The former CLI
      // shim (usr/libexec/singbox-ui/bbolt-client) existed only for argv
      // compatibility with a Rust binary that no longer exists; it now lives in
      // bbolt-client/ as a test driver for the golden harness and must not ship.
      expect(existsSync(join(root, "usr/share/singbox-ui/lib/bbolt.uc"))).toBe(
        true,
      );
      expect(
        existsSync(join(root, "usr/libexec/singbox-ui/bbolt-client")),
      ).toBe(false);
      const src = readFileSync(
        resolve(ROOT, "singbox-ui/root/usr/share/singbox-ui/nft-rulesets.uc"),
        "utf8",
      );
      // In-process require, and no trace of the forked binary it replaced.
      // (Not asserting the absence of "/bin/sh" outright: nft-rulesets.uc still
      // shells out for the nft apply command line, which is unrelated.)
      expect(src).toContain('require("bbolt")');
      expect(src).not.toContain("bbolt-client");
      expect(src).not.toContain("SINGBOX_BBOLT_BIN");
    },
  );

  it.skipIf(!hasBash)(
    "stale prior-version .apks are removed before build",
    () => {
      const work = mkdtempSync(resolve(tmpdir(), "apk-stale-"));
      const out = resolve(work, "dist");
      mkdirSync(out, { recursive: true });

      // Plant stale .apks from a prior version (0.0.0-r0) alongside unrelated files
      writeFileSync(resolve(out, "singbox-ui_0.0.0-r0.apk"), "stale");
      writeFileSync(resolve(out, "luci-app-singbox-ui_0.0.0-r0.apk"), "stale");
      writeFileSync(
        resolve(out, "luci-i18n-singbox-ui-ru_0.0.0-r0.apk"),
        "stale",
      );
      writeFileSync(resolve(out, "unrelated-package_1.2.3.apk"), "keep me");

      // Run build-apk.sh with new version (0.0.0-r1)
      const result = spawnSync("bash", [BUILDSH, "0.0.0-r1", out], {
        cwd: ROOT,
        encoding: "utf8",
        env: {
          ...process.env,
          APK_MKPKG_STUB: "1",
          WORK_DIR: resolve(work, ".build"),
        },
      });

      try {
        expect(result.status).toBe(0);

        const files = readdirSync(out);
        // Stale prior-version .apks must be gone
        expect(files).not.toContain("singbox-ui_0.0.0-r0.apk");
        expect(files).not.toContain("luci-app-singbox-ui_0.0.0-r0.apk");
        expect(files).not.toContain("luci-i18n-singbox-ui-ru_0.0.0-r0.apk");
        // Unrelated .apk must survive
        expect(files).toContain("unrelated-package_1.2.3.apk");
        // New version .apks must be present
        expect(files).toContain("singbox-ui_0.0.0-r1.apk");
        expect(files).toContain("luci-app-singbox-ui_0.0.0-r1.apk");
        expect(files).toContain("luci-i18n-singbox-ui-ru_0.0.0-r1.apk");
      } finally {
        rmSync(work, { recursive: true, force: true });
      }
    },
  );

  // Per-package versioning: each package's filename (and therefore its apk
  // metadata version, set from the same V_* var) must carry its OWN
  // PKG_VER_<PKG> override. An unset override falls back to the positional
  // version. Regression for the rolling-feed behaviour where an unchanged
  // package keeps its version across pushes that didn't touch it.
  it.skipIf(!hasBash)(
    "PKG_VER_* override each package's version independently",
    () => {
      const work = mkdtempSync(resolve(tmpdir(), "apk-perpkg-ver-"));
      const out = resolve(work, "dist");

      // Distinct version per package; I18N intentionally left UNSET so it falls
      // back to the positional 0.0.0-r99.
      const result = spawnSync("bash", [BUILDSH, "0.0.0-r99", out], {
        cwd: ROOT,
        encoding: "utf8",
        env: {
          ...process.env,
          APK_MKPKG_STUB: "1",
          WORK_DIR: resolve(work, ".build"),
          PKG_VER_SINGBOX: "0.1.0-r10",
          PKG_VER_LUCIAPP: "0.1.0-r7",
          PKG_VER_AWGWARP: "0.1.0-r2",
        },
      });

      try {
        expect(result.status).toBe(0);
        const files = readdirSync(out);
        // Each package carries its own override.
        expect(files).toContain("singbox-ui_0.1.0-r10.apk");
        expect(files).toContain("luci-app-singbox-ui_0.1.0-r7.apk");
        expect(files).toContain("singbox-ui-plugin-awg_warp_0.1.0-r2.apk");
        // Unset override -> positional fallback.
        expect(files).toContain("luci-i18n-singbox-ui-ru_0.0.0-r99.apk");
        // The mixed positional must NOT leak onto an overridden package.
        expect(files).not.toContain("singbox-ui_0.0.0-r99.apk");
      } finally {
        rmSync(work, { recursive: true, force: true });
      }
    },
  );

  it.skipIf(!hasBash)(
    "every file under singbox-ui/root/ lands in the built package root",
    () => {
      const { work } = ensureBuild();
      const dst = resolve(work, ".build/pkg-root-singbox-ui");
      // Ground truth is git's index, not a re-walk of singbox-ui/root/: the
      // build (cp -a) and a re-walk both read the same live working tree, so
      // a file deleted from disk would silently vanish from both sides and
      // the test could never fail. `git ls-files` still lists a tracked file
      // even after it's removed from the working tree without `git rm`,
      // which is exactly what makes this catch a build that drops a file.
      const lsFiles = spawnSync("git", ["ls-files", "--", "singbox-ui/root"], {
        cwd: ROOT,
        encoding: "utf8",
      });
      const want = lsFiles.stdout
        .split("\n")
        .filter(Boolean)
        .map((f) => f.slice("singbox-ui/root/".length));
      expect(want.length).toBeGreaterThan(0);
      for (const rel of want)
        expect(existsSync(join(dst, rel)), `packaged: ${rel}`).toBe(true);
    },
  );

  // D4.5/E: the core backend package must ship ONLY plugin infrastructure
  // under lib/plugins/ — registry.uc + discovery.uc. Actual plugins ship
  // their own lib/plugins/<name>/ subtree from their own package (e.g.
  // singbox-ui-plugin-awg_warp), never from core. Formerly guarded by
  // reading the generated install manifest (tests/cross/test_install_manifest_fresh.test.ts,
  // deleted alongside it); since populate_singbox_root now does a plain
  // `cp -a` of singbox-ui/root/ into the package root, what core ships is
  // identical to what's in the source tree, so this checks the source
  // directly — no build required.
  it("D4.5/E: core ships only plugin INFRASTRUCTURE under lib/plugins/ (registry.uc + discovery.uc); no plugin payloads", () => {
    const dir = resolve(
      ROOT,
      "singbox-ui/root/usr/share/singbox-ui/lib/plugins",
    );
    expect(readdirSync(dir).sort()).toEqual(["discovery.uc", "registry.uc"]);
  });
});
