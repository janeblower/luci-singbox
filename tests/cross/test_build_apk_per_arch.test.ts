/**
 * tests/cross/build_apk_per_arch.test.ts
 * Port of tests/cross/test_build_apk_per_arch.sh
 *
 * Asserts scripts/build-apk.sh produces the FIVE-package split:
 *   - bbolt-client_<ver>_<arch>.apk            one per covered OpenWrt arch (20 total)
 *   - singbox-ui_<ver>.apk                     noarch backend
 *   - luci-app-singbox-ui_<ver>.apk            noarch LuCI frontend
 *   - luci-i18n-singbox-ui-ru_<ver>.apk        noarch Russian translation
 *   - luci-app-singbox-plugin-awg-warp_<ver>.apk  noarch AWG-WARP plugin
 *
 * Driven via APK_MKPKG_STUB=1 (no SDK needed). SKIPs if bash is unavailable
 * (e.g. OpenWrt qemu guest has only BusyBox ash).
 */
import { describe, expect, it } from "bun:test";
import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";

const ROOT = resolve(import.meta.dir, "../..");
const BUILDSH = resolve(ROOT, "scripts/build-apk.sh");

// Skip guard: build-apk.sh is bash-only; reproduce the exact shell guard.
const bashCheck = spawnSync("bash", ["--version"], { encoding: "utf8" });
const hasBash = bashCheck.status === 0 && !bashCheck.error;

// Lazily-built output (only when bash is available)
type BuildResult = {
  out: string;
  work: string;
  binDir: string;
};

let buildResult: BuildResult | null = null;
let buildError: string | null = null;

function ensureBuild(): BuildResult {
  if (buildResult) return buildResult;
  if (buildError) throw new Error(buildError);

  const work = mkdtempSync(resolve(tmpdir(), "apk-per-arch-"));
  const binDir = resolve(work, "bins");
  mkdirSync(binDir, { recursive: true });
  const out = resolve(work, "dist");

  // Create fake bbolt binaries for the 5 ABI families build-apk.sh knows about
  for (const abi of ["x86_64", "aarch64", "armv7", "mipsel", "mips"]) {
    writeFileSync(resolve(binDir, `bbolt-client-rs-${abi}`), `BBOLT-${abi}\n`);
  }

  const result = spawnSync("bash", [BUILDSH, "0.0.0-r1", out], {
    cwd: ROOT,
    encoding: "utf8",
    env: {
      ...process.env,
      APK_MKPKG_STUB: "1",
      BBOLT_BIN_DIR: binDir,
      WORK_DIR: resolve(work, ".build"),
    },
  });

  if (result.status !== 0) {
    buildError = `build-apk.sh failed:\n${result.stderr}`;
    rmSync(work, { recursive: true, force: true });
    throw new Error(buildError);
  }

  buildResult = { out, work, binDir };
  return buildResult;
}

describe("build_apk_per_arch", () => {
  it.skipIf(!hasBash)(
    "per-arch bbolt-client: exactly 20 (one per arch in the map)",
    () => {
      const { out } = ensureBuild();
      const apks = readdirSync(out).filter((f) =>
        /^bbolt-client_0\.0\.0-r1_.*\.apk$/.test(f),
      );
      expect(apks.length).toBe(20);
    },
  );

  it.skipIf(!hasBash)("four noarch packages: exactly one each", () => {
    const { out } = ensureBuild();
    for (const name of [
      "singbox-ui",
      "luci-app-singbox-ui",
      "luci-i18n-singbox-ui-ru",
      "luci-app-singbox-plugin-awg-warp",
    ]) {
      const apks = readdirSync(out).filter((f) => f === `${name}_0.0.0-r1.apk`);
      expect(apks.length).toBe(1);
    }
  });

  it.skipIf(!hasBash)(
    "total apk count is exactly 24 (20 bbolt + 4 noarch)",
    () => {
      const { out } = ensureBuild();
      const total = readdirSync(out).filter((f) => f.endsWith(".apk")).length;
      expect(total).toBe(24);
    },
  );

  it.skipIf(!hasBash)(
    "bbolt binary belongs to bbolt-client package, NOT the backend",
    () => {
      const { work } = ensureBuild();
      const buildDir = resolve(work, ".build");
      for (const probe of [
        { arch: "aarch64_cortex-a53", abi: "aarch64" },
        { arch: "mipsel_24kc", abi: "mipsel" },
        { arch: "x86_64", abi: "x86_64" },
      ]) {
        const root = resolve(
          buildDir,
          `pkg-root-bbolt-${probe.arch}`,
          "usr/libexec/singbox-ui/bbolt-client",
        );
        expect(existsSync(root)).toBe(true);
        const content = require("node:fs").readFileSync(root, "utf8");
        expect(content).toContain(`BBOLT-${probe.abi}`);
      }
    },
  );

  it.skipIf(!hasBash)(
    "noarch backend root must NOT carry the bbolt binary",
    () => {
      const { work } = ensureBuild();
      const backendBbolt = resolve(
        work,
        ".build/pkg-root-singbox-ui/usr/libexec/singbox-ui/bbolt-client",
      );
      expect(existsSync(backendBbolt)).toBe(false);
    },
  );

  it.skipIf(!hasBash)(
    "stale prior-version .apks are removed before build",
    () => {
      const work = mkdtempSync(resolve(tmpdir(), "apk-stale-"));
      const binDir = resolve(work, "bins");
      mkdirSync(binDir, { recursive: true });
      const out = resolve(work, "dist");
      mkdirSync(out, { recursive: true });

      // Create fake bbolt binaries for all 5 ABIs
      for (const abi of ["x86_64", "aarch64", "armv7", "mipsel", "mips"]) {
        writeFileSync(
          resolve(binDir, `bbolt-client-rs-${abi}`),
          `BBOLT-${abi}\n`,
        );
      }

      // Plant stale .apks from a prior version (0.0.0-r0) alongside unrelated files
      writeFileSync(resolve(out, "singbox-ui_0.0.0-r0.apk"), "stale");
      writeFileSync(resolve(out, "luci-app-singbox-ui_0.0.0-r0.apk"), "stale");
      writeFileSync(
        resolve(out, "luci-i18n-singbox-ui-ru_0.0.0-r0.apk"),
        "stale",
      );
      writeFileSync(resolve(out, "bbolt-client_0.0.0-r0_x86_64.apk"), "stale");
      writeFileSync(resolve(out, "unrelated-package_1.2.3.apk"), "keep me");

      // Run build-apk.sh with new version (0.0.0-r1)
      const result = spawnSync("bash", [BUILDSH, "0.0.0-r1", out], {
        cwd: ROOT,
        encoding: "utf8",
        env: {
          ...process.env,
          APK_MKPKG_STUB: "1",
          BBOLT_BIN_DIR: binDir,
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
        expect(files).not.toContain("bbolt-client_0.0.0-r0_x86_64.apk");
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
});
