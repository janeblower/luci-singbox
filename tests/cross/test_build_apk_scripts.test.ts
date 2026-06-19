/**
 * tests/cross/build_apk_scripts.test.ts
 * Port of tests/cross/test_build_apk_scripts.sh
 *
 * Verifies scripts/build-apk.sh emits the explicit init.d enable+start
 * invocations in its package lifecycle scripts.
 */
import { describe, expect, it } from "bun:test";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";

const ROOT = resolve(import.meta.dir, "../..");
const BUILDSH = resolve(ROOT, "scripts/build-apk.sh");

function readBuildApk(): string {
  return require("node:fs").readFileSync(BUILDSH, "utf8");
}

const hasBuildSh = existsSync(BUILDSH);

describe("build_apk_scripts", () => {
  it("scripts/build-apk.sh exists", () => {
    expect(hasBuildSh).toBe(true);
  });

  it.skipIf(!hasBuildSh)("post-install enables and starts singbox-ui", () => {
    const src = readBuildApk();
    expect(src).toContain("/etc/init.d/singbox-ui enable");
    expect(src).toContain("/etc/init.d/singbox-ui start");
  });

  it.skipIf(!hasBuildSh)(
    "post-upgrade restarts (not stop+start) for minimal downtime",
    () => {
      const src = readBuildApk();
      expect(src).toContain("/etc/init.d/singbox-ui restart");
    },
  );

  it.skipIf(!hasBuildSh)("pre-deinstall stops and disables", () => {
    const src = readBuildApk();
    expect(src).toContain("/etc/init.d/singbox-ui stop");
    expect(src).toContain("/etc/init.d/singbox-ui disable");
  });

  it.skipIf(!hasBuildSh)(
    "no silent fakeroot fallback (SDK apk wrapper hijacks LD_PRELOAD)",
    () => {
      const src = readBuildApk();
      // A bare 'fakeroot ' in the run-builder branch would silently produce
      // nobody:nogroup packages. Only 'as root' or 'unshare -r' are acceptable.
      const hasFakeroot = /^\s*fakeroot\s+sh/m.test(src);
      expect(hasFakeroot).toBe(false);
      expect(src).toContain("verify_root_owner");
    },
  );

  it.skipIf(!hasBuildSh)(
    "version derived from git tag when no arg is passed",
    () => {
      // Skip if git is not available (e.g. OpenWrt rootfs in CI Docker env)
      const gitCheck = spawnSync("git", ["--version"], { encoding: "utf8" });
      if (gitCheck.status !== 0 || gitCheck.error) {
        console.log("  SKIP (git not available)");
        return;
      }

      // Create a temporary git tag and run the script with a fake git shim
      // that only answers 'describe --tags --abbrev=0' so the rest never runs.
      const TEST_TAG = "v9.9.9-test";
      const fakeDir = mkdtempSync(resolve(tmpdir(), "apkscripts-"));
      try {
        // Create the tag
        spawnSync("git", ["tag", TEST_TAG], {
          cwd: ROOT,
          stdio: "ignore",
        });

        // Build a fake git shim
        const fakeGit = resolve(fakeDir, "git");
        writeFileSync(
          fakeGit,
          `#!/bin/sh\nif [ "$1" = "describe" ]; then echo "${TEST_TAG}"; else command git "$@"; fi\n`,
          { mode: 0o755 },
        );

        // Run the script; it may fail after printing the version line (SDK download)
        const env = {
          ...process.env,
          PATH: `${fakeDir}:${process.env.PATH}`,
        };
        const result = spawnSync("bash", [BUILDSH], {
          cwd: ROOT,
          env,
          encoding: "utf8",
        });
        const output = result.stdout ?? "";

        expect(output).toContain("using version from git tag: 9.9.9-test");
      } finally {
        // Clean up tag
        spawnSync("git", ["tag", "-d", TEST_TAG], {
          cwd: ROOT,
          stdio: "ignore",
        });
        rmSync(fakeDir, { recursive: true, force: true });
      }
    },
  );
});
