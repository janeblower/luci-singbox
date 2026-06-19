/**
 * tests/cross/build_feed.test.ts
 * Port of tests/cross/test_build_feed.sh
 *
 * Tests scripts/build-feed.sh against REAL apk-tools 3 (apk mkpkg --info).
 * SKIPs inside the OpenWrt qemu VM (SINGBOX_TESTS_IN_VM=1).
 * SKIPs (or hard-fails) if apk-tools 3.0.5+ with mkpkg --info is unavailable;
 * the only escape is SINGBOX_FEED_TEST_ALLOW_SKIP=1.
 */
import { describe, expect, it } from "bun:test";
import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";

const ROOT = resolve(import.meta.dir, "../..");

// --- Skip / probe logic (mirrors the shell script exactly) ------------------

const IN_VM = process.env.SINGBOX_TESTS_IN_VM === "1";
const ALLOW_SKIP = process.env.SINGBOX_FEED_TEST_ALLOW_SKIP === "1";

/** Locate an apk-tools 3 binary, or return null. */
function findApk(): string | null {
  const override = process.env.SINGBOX_APK_BIN;
  if (override) return override;
  const onPath = spawnSync("command", ["-v", "apk"], {
    shell: true,
    encoding: "utf8",
  });
  if (onPath.status === 0 && onPath.stdout.trim()) return onPath.stdout.trim();
  const sdk = resolve(ROOT, ".build/sdk/staging_dir/host/bin/apk");
  if (existsSync(sdk)) return sdk;
  return null;
}

function hasApk3WithInfo(apk: string): boolean {
  const ver = spawnSync(apk, ["--version"], { encoding: "utf8" });
  if (!ver.stdout.includes("apk-tools 3")) return false;
  const help = spawnSync(apk, ["mkpkg", "--help"], { encoding: "utf8" });
  const helpOut = (help.stdout ?? "") + (help.stderr ?? "");
  return helpOut.includes("--info");
}

// Evaluate capability once at module level — but DON'T throw yet.
const apkBin = IN_VM ? null : findApk();
const capable = apkBin !== null && hasApk3WithInfo(apkBin);

// skip_or_fail semantics (mirrors the shell exactly):
//   - IN_VM=1                    → always SKIP (benign; qemu guest lacks mkpkg --info)
//   - !capable + ALLOW_SKIP=1   → SKIP (explicit escape for environments without apk)
//   - !capable + ALLOW_SKIP=0   → hard-FAIL (packaging lane MUST have apk-tools 3.0.5+)
//   - capable                   → RUN
const skipAll = IN_VM || (!capable && ALLOW_SKIP);

// Module-level hard-fail: mirrors skip_or_fail() in the shell — throws immediately
// (not inside an it()) when apk is absent and ALLOW_SKIP was not set.
if (!IN_VM && !capable && !ALLOW_SKIP) {
  const reason = apkBin
    ? `apk-tools 3 with --info not found (${apkBin})`
    : "no apk binary on PATH or SDK build";
  throw new Error(
    `missing capability: ${reason} (need apk-tools 3.0.5+; ` +
      `set SINGBOX_FEED_TEST_ALLOW_SKIP=1 only if truly unavailable)`,
  );
}

/** Guard inside each test body: redundant safety net; the module-level throw
 *  above already fires first, but this preserves the per-test message context. */
function requireCapable(): void {
  if (capable || IN_VM) return;
  if (ALLOW_SKIP) return;
  const reason = apkBin
    ? `apk-tools 3 with --info not found (${apkBin})`
    : "no apk binary on PATH or SDK build";
  throw new Error(
    `missing capability: ${reason} (need apk-tools 3.0.5+; ` +
      `set SINGBOX_FEED_TEST_ALLOW_SKIP=1 only if truly unavailable)`,
  );
}

// Arch list from the shell script (20 covered arches, matches COVERED_ARCHES)
const ARCHES_FROM_SH = `x86_64 \
aarch64_cortex-a53 aarch64_cortex-a72 aarch64_cortex-a76 aarch64_generic \
arm_cortex-a5_vfpv4 arm_cortex-a7 arm_cortex-a7_neon-vfpv4 arm_cortex-a7_vfpv4 \
arm_cortex-a8_vfpv3 arm_cortex-a9 arm_cortex-a9_neon arm_cortex-a9_vfpv3-d16 \
arm_cortex-a15_neon-vfpv4 \
mipsel_24kc mipsel_24kc_24kf mipsel_74kc mipsel_mips32 \
mips_24kc mips_mips32`
  .split(/\s+/)
  .filter(Boolean);

// ---------------------------------------------------------------------------
// Build the feed once (lazy, only when capable)
// ---------------------------------------------------------------------------

type FeedResult = {
  tmp: string;
  out: string;
  dist: string;
};

let feedResult: FeedResult | null = null;
let feedError: string | null = null;

function ensureFeed(): FeedResult {
  if (feedResult) return feedResult;
  if (feedError) throw new Error(feedError);
  if (!apkBin) throw new Error("no apk");

  const tmp = mkdtempSync(resolve(tmpdir(), "build-feed-"));
  const dist = resolve(tmp, "dist");
  const out = resolve(tmp, "out");
  mkdirSync(dist, { recursive: true });

  // Per-arch bbolt-client apks
  mkdirSync(resolve(tmp, "b/x"), { recursive: true });
  writeFileSync(resolve(tmp, "b/x/a"), "a\n");
  for (const arch of ARCHES_FROM_SH) {
    const r = spawnSync(
      apkBin,
      [
        "mkpkg",
        "--info",
        `name:bbolt-client`,
        "--info",
        `version:9.9.9-r1`,
        "--info",
        `arch:${arch}`,
        "--info",
        "description:t",
        "--info",
        "license:GPL-2.0-or-later",
        "--files",
        "x",
        "-o",
        resolve(dist, `bbolt-client-${arch}.apk`),
      ],
      { cwd: resolve(tmp, "b"), encoding: "utf8" },
    );
    if (r.status !== 0) {
      feedError = `mkpkg bbolt-client-${arch} failed: ${r.stderr}`;
      rmSync(tmp, { recursive: true, force: true });
      throw new Error(feedError);
    }
  }

  // Noarch core
  mkdirSync(resolve(tmp, "c/x"), { recursive: true });
  writeFileSync(resolve(tmp, "c/x/b"), "b\n");
  spawnSync(
    apkBin,
    [
      "mkpkg",
      "--info",
      "name:singbox-ui",
      "--info",
      "version:9.9.9-r1",
      "--info",
      "arch:all",
      "--info",
      "description:t",
      "--info",
      "license:GPL-2.0-or-later",
      "--files",
      "x",
      "-o",
      resolve(dist, "singbox-ui.apk"),
    ],
    { cwd: resolve(tmp, "c"), encoding: "utf8" },
  );

  // Noarch LuCI app
  mkdirSync(resolve(tmp, "a/x"), { recursive: true });
  writeFileSync(resolve(tmp, "a/x/c"), "c\n");
  spawnSync(
    apkBin,
    [
      "mkpkg",
      "--info",
      "name:luci-app-singbox-ui",
      "--info",
      "version:9.9.9-r1",
      "--info",
      "arch:all",
      "--info",
      "description:t",
      "--info",
      "license:GPL-2.0-or-later",
      "--files",
      "x",
      "-o",
      resolve(dist, "luci-app-singbox-ui.apk"),
    ],
    { cwd: resolve(tmp, "a"), encoding: "utf8" },
  );

  // Noarch i18n
  mkdirSync(resolve(tmp, "i/x"), { recursive: true });
  writeFileSync(resolve(tmp, "i/x/d"), "d\n");
  spawnSync(
    apkBin,
    [
      "mkpkg",
      "--info",
      "name:luci-i18n-singbox-ui-ru",
      "--info",
      "version:9.9.9-r1",
      "--info",
      "arch:all",
      "--info",
      "description:t",
      "--info",
      "license:GPL-2.0-or-later",
      "--files",
      "x",
      "-o",
      resolve(dist, "luci-i18n-singbox-ui-ru.apk"),
    ],
    { cwd: resolve(tmp, "i"), encoding: "utf8" },
  );

  // Dummy public key
  writeFileSync(resolve(tmp, "pub.pem"), "DUMMY PUBLIC KEY\n");

  // Run build-feed.sh
  const feedRun = spawnSync(
    "sh",
    [resolve(ROOT, "scripts/build-feed.sh"), "25.12", dist, out],
    {
      cwd: ROOT,
      encoding: "utf8",
      env: {
        ...process.env,
        FEED_PUBKEY: resolve(tmp, "pub.pem"),
        PAGES_URL: "https://example.test/luci-singbox",
        RELEASE_REPO: "acme/luci-singbox",
        APK_BIN: apkBin,
      },
    },
  );

  if (feedRun.status !== 0) {
    feedError = `build-feed.sh failed:\n${feedRun.stderr}\n${feedRun.stdout}`;
    rmSync(tmp, { recursive: true, force: true });
    throw new Error(feedError);
  }

  feedResult = { tmp, out, dist };
  return feedResult;
}

// ---------------------------------------------------------------------------

describe("build_feed", () => {
  it.skipIf(skipAll)(
    "REGRESSION GUARD (FEED-1): feed_pkg_filename anchors on top-level name/version",
    () => {
      requireCapable();
      // Verify the literal awk program text is still in build-feed.sh
      const buildFeedSh = readFileSync(
        resolve(ROOT, "scripts/build-feed.sh"),
        "utf8",
      );
      expect(buildFeedSh).toContain('/^  name: /    && n=="" { n=$2 }');

      // Crafted dump: decoy nested name/version after the real fields
      const dump =
        "  name: bbolt-client\n" +
        "  version: 9.9.9-r1\n" +
        "  arch: x86_64\n" +
        "  scripts:\n" +
        "    triggers:\n" +
        "      name: should-be-ignored\n" +
        "      version: 0.0.0-r0\n";

      const parser =
        '    /^  name: /    && n=="" { n=$2 }\n' +
        '    /^  version: / && v=="" { v=$2 }\n' +
        '    n!="" && v!=""          { printf "%s-%s.apk\\n", n, v; exit }\n' +
        '    END { if (n=="" || v=="") exit 1 }';

      const dumpTmp = mkdtempSync(resolve(tmpdir(), "feed1-"));
      const dumpFile = resolve(dumpTmp, "dump");
      try {
        writeFileSync(dumpFile, dump);
        const r = spawnSync("awk", [parser, dumpFile], { encoding: "utf8" });
        expect(r.status).toBe(0);
        expect(r.stdout.trim()).toBe("bbolt-client-9.9.9-r1.apk");
      } finally {
        rmSync(dumpTmp, { recursive: true, force: true });
      }
    },
  );

  it.skipIf(skipAll)(
    "per-arch: every arch dir holds four <name>-<version>.apk files + packages.adb",
    () => {
      requireCapable();
      const { out } = ensureFeed();
      for (const arch of ARCHES_FROM_SH) {
        const d = resolve(out, `25.12/${arch}/luci-singbox`);
        expect(existsSync(d)).toBe(true);

        // Named <name>-<version>.apk (not release-asset names)
        expect(existsSync(resolve(d, "bbolt-client-9.9.9-r1.apk"))).toBe(true);
        expect(existsSync(resolve(d, "singbox-ui-9.9.9-r1.apk"))).toBe(true);
        expect(existsSync(resolve(d, "luci-app-singbox-ui-9.9.9-r1.apk"))).toBe(
          true,
        );
        expect(
          existsSync(resolve(d, "luci-i18n-singbox-ui-ru-9.9.9-r1.apk")),
        ).toBe(true);

        // Release-asset name must NOT appear
        expect(existsSync(resolve(d, `bbolt-client-${arch}.apk`))).toBe(false);

        // packages.adb index present
        expect(existsSync(resolve(d, "packages.adb"))).toBe(true);

        // Exactly 4 apks
        const napk = readdirSync(d).filter((f) => f.endsWith(".apk")).length;
        expect(napk).toBe(4);

        // Every package referenced by the index exists on disk
        const dump = spawnSync(
          apkBin!,
          ["adbdump", resolve(d, "packages.adb")],
          {
            encoding: "utf8",
          },
        );
        const wantFiles = new Set<string>();
        let lastN = "";
        for (const line of dump.stdout.split("\n")) {
          const nm = line.match(/name:\s*(\S+)/);
          if (nm) lastN = nm[1];
          const vm = line.match(/version:\s*(\S+)/);
          if (vm && lastN) {
            wantFiles.add(`${lastN}-${vm[1]}.apk`);
            lastN = "";
          }
        }
        for (const want of wantFiles) {
          expect(existsSync(resolve(d, want))).toBe(true);
        }
      }
    },
  );

  it.skipIf(skipAll)("exactly 20 arch dirs were produced", () => {
    requireCapable();
    const { out } = ensureFeed();
    const dirs = readdirSync(resolve(out, "25.12")).filter((f) => {
      const st = statSync(resolve(out, "25.12", f), { throwIfNoEntry: false });
      return st?.isDirectory();
    });
    expect(dirs.length).toBe(20);
  });

  it.skipIf(skipAll)("public key published at feed root", () => {
    requireCapable();
    const { out } = ensureFeed();
    expect(existsSync(resolve(out, "luci-singbox.pem"))).toBe(true);
  });

  it.skipIf(skipAll)(
    "build-feed emits Jekyll sources (_config.yml, NOT index.html)",
    () => {
      requireCapable();
      const { out } = ensureFeed();
      expect(existsSync(resolve(out, "_config.yml"))).toBe(true);
      const config = readFileSync(resolve(out, "_config.yml"), "utf8");
      expect(config).toContain("jekyll-theme-midnight");
      expect(existsSync(resolve(out, "index.html"))).toBe(false);
    },
  );

  it.skipIf(skipAll)(
    "root landing (index.md) rendered with substitutions, no junk",
    () => {
      requireCapable();
      const { out } = ensureFeed();
      expect(existsSync(resolve(out, "index.md"))).toBe(true);
      const md = readFileSync(resolve(out, "index.md"), "utf8");

      expect(md).toContain("example.test/luci-singbox");
      expect(md).toContain("apk add luci-app-singbox-ui");
      expect(md).toContain("packages.adb");
      expect(md).toContain("github.com/acme/luci-singbox");

      expect(md).not.toContain("luci-singbox-ui-");
      expect(md).not.toContain("{{");
      expect(md.toLowerCase()).not.toContain("ipk");
      expect(md).not.toContain("releases/download/latest");
    },
  );

  it.skipIf(skipAll)(
    "browsable Jekyll indexes at version + arch levels with front matter",
    () => {
      requireCapable();
      const { out } = ensureFeed();
      expect(existsSync(resolve(out, "25.12/index.md"))).toBe(true);
      expect(existsSync(resolve(out, "25.12/x86_64/index.md"))).toBe(true);
      const vIdx = readFileSync(resolve(out, "25.12/index.md"), "utf8");
      expect(vIdx).toContain("layout: default");
    },
  );

  it.skipIf(skipAll)(
    "arch list derived from filenames: never-built arch must not appear",
    () => {
      requireCapable();
      const { out } = ensureFeed();
      expect(existsSync(resolve(out, "25.12/riscv64"))).toBe(false);
    },
  );
});
