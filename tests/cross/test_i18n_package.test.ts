/**
 * tests/cross/i18n_package.test.ts
 * Port of tests/cross/test_i18n_package.sh
 *
 * i18n-package integration (goal d). Asserts the Russian translation package
 * is built correctly by scripts/build-apk.sh:
 *   1. .po source basename is the UN-renamed i18n domain `luci-singbox-ui`
 *   2. build-apk lays the .lmo into the i18n package root at
 *      usr/lib/lua/luci/i18n/luci-singbox-ui.ru.lmo
 *   3. produced luci-i18n-singbox-ui-ru .apk DEPENDS luci-app-singbox-ui
 *   4. when a real SDK apk + po2lmo exist, the .lmo is a non-empty compiled file
 *
 * SKIPs if bash is unavailable (build-apk.sh needs bash).
 */

import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

const ROOT = resolve(import.meta.dirname, "../..");
const BUILDSH = resolve(ROOT, "scripts/build-apk.sh");

// Skip guard: build-apk.sh needs bash.
const bashCheck = spawnSync("bash", ["--version"], { encoding: "utf8" });
const hasBash = bashCheck.status === 0 && !bashCheck.error;

const DOMAIN = "luci-singbox-ui";
const I18N_NAME = "luci-i18n-singbox-ui-ru";
const PO = resolve(ROOT, `luci-app-singbox-ui/po/ru/${DOMAIN}.po`);

// Lazily-built stub output
type StubBuildResult = { tmp: string; buildDir: string };
let stubResult: StubBuildResult | null = null;
let stubError: string | null = null;

function ensureStubBuild(): StubBuildResult {
  if (stubResult) return stubResult;
  if (stubError) throw new Error(stubError);

  const tmp = mkdtempSync(resolve(tmpdir(), "i18n-pkg-"));
  const buildDir = resolve(tmp, "build");
  mkdirSync(buildDir, { recursive: true });

  const result = spawnSync(
    "bash",
    [BUILDSH, "0.0.0-r1", resolve(tmp, "dist")],
    {
      cwd: ROOT,
      encoding: "utf8",
      env: {
        ...process.env,
        APK_MKPKG_STUB: "1",
        WORK_DIR: buildDir,
      },
    },
  );

  if (result.status !== 0) {
    stubError = `build-apk.sh (stub) failed:\n${result.stderr}`;
    rmSync(tmp, { recursive: true, force: true });
    throw new Error(stubError);
  }

  stubResult = { tmp, buildDir };
  return stubResult;
}

describe("i18n_package", () => {
  it.skipIf(!hasBash)(
    "(1) .po source carries the un-renamed domain basename",
    () => {
      expect(existsSync(PO)).toBe(true);
    },
  );

  it.skipIf(!hasBash)(
    "(2) .lmo lands in i18n package root under the un-renamed domain name",
    () => {
      const { buildDir } = ensureStubBuild();
      const lmo = resolve(
        buildDir,
        `pkg-root-i18n-ru/usr/lib/lua/luci/i18n/${DOMAIN}.ru.lmo`,
      );
      expect(existsSync(lmo)).toBe(true);

      // The package's .list must reference that .lmo path
      const list = resolve(
        buildDir,
        `pkg-root-i18n-ru/lib/apk/packages/${I18N_NAME}.list`,
      );
      expect(existsSync(list)).toBe(true);
      const listContent = readFileSync(list, "utf8");
      expect(listContent).toContain(`/usr/lib/lua/luci/i18n/${DOMAIN}.ru.lmo`);
    },
  );

  it.skipIf(!hasBash)(
    "(3) I18N_DEPENDS is 'libc $LUCIAPP_NAME' and LUCIAPP_NAME is 'luci-app-singbox-ui'",
    () => {
      const src = readFileSync(BUILDSH, "utf8");
      // grep -Eq '^I18N_DEPENDS="libc \$LUCIAPP_NAME"$'
      expect(/^I18N_DEPENDS="libc \$LUCIAPP_NAME"$/m.test(src)).toBe(true);
      // grep -Eq '^LUCIAPP_NAME="luci-app-singbox-ui"$'
      expect(/^LUCIAPP_NAME="luci-app-singbox-ui"$/m.test(src)).toBe(true);
    },
  );

  it.skipIf(!hasBash)(
    "(4) real po2lmo content check (skip if SDK apk+po2lmo absent)",
    () => {
      // Locate SDK apk
      let apkBin = process.env.SINGBOX_APK_BIN ?? "";
      if (!apkBin) {
        const sdk = resolve(ROOT, ".build/sdk/staging_dir/host/bin/apk");
        if (existsSync(sdk)) apkBin = sdk;
      }
      const po2lmoPath = resolve(
        ROOT,
        ".build/sdk/staging_dir/hostpkg/bin/po2lmo",
      );
      const hasSdkApk3 =
        apkBin !== "" &&
        spawnSync(apkBin, ["--version"], { encoding: "utf8" }).stdout.includes(
          "apk-tools 3",
        );
      const hasPo2lmo = existsSync(po2lmoPath);

      if (!hasSdkApk3 || !hasPo2lmo) {
        console.log(
          "note: real po2lmo content check skipped (no SDK apk+po2lmo); " +
            "naming+DEPENDS contract still verified",
        );
        return; // benign skip of sub-check
      }

      const tmp2 = mkdtempSync(resolve(tmpdir(), "i18n-real-"));
      try {
        const realBuildDir = resolve(tmp2, "realbuild");
        const realOut = resolve(tmp2, "realdist");
        mkdirSync(realBuildDir, { recursive: true });

        const r = spawnSync("bash", [BUILDSH, "0.0.0-r1", realOut], {
          cwd: ROOT,
          encoding: "utf8",
          env: {
            ...process.env,
            SINGBOX_SKIP_BBOLT: "1",
            WORK_DIR: realBuildDir,
          },
        });
        expect(r.status).toBe(0);

        const realLmo = resolve(
          realBuildDir,
          `pkg-root-i18n-ru/usr/lib/lua/luci/i18n/${DOMAIN}.ru.lmo`,
        );
        const lmoStat = require("node:fs").statSync(realLmo, {
          throwIfNoEntry: false,
        });
        expect(lmoStat?.size ?? 0).toBeGreaterThan(0);

        const apkFile = resolve(realOut, `${I18N_NAME}_0.0.0-r1.apk`);
        expect(existsSync(apkFile)).toBe(true);

        const dump = spawnSync(apkBin, ["adbdump", apkFile], {
          encoding: "utf8",
        });
        // Must declare depends: luci-app-singbox-ui
        const dumpOut = dump.stdout + (dump.stderr ?? "");
        // grep -A20 -i 'depends' | grep -q 'luci-app-singbox-ui'
        const depSection =
          dumpOut
            .split("\n")
            .join("\n")
            .match(/depends[\s\S]{0,500}/i)?.[0] ?? "";
        expect(depSection).toContain("luci-app-singbox-ui");
      } finally {
        rmSync(tmp2, { recursive: true, force: true });
      }
    },
  );
});
