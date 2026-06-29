/**
 * tests/cross/install_sh.test.ts
 * Port of tests/cross/test_install_sh.sh
 *
 * Unit test for the FEED-based install.sh. Drives the flow WITHOUT network:
 * stubs `apk` (--print-arch / update / add / list) and `wget` via PATH + temp dir;
 * redirects /etc/apk/... root paths via APK_KEYS_DIR / APK_REPO_DIR env hooks.
 *
 * Eight tests:
 *   TEST 1: happy path (x86_64) — key fetched, repo list written, no apk add
 *   TEST 2: unsupported arch aborts non-zero, no repo list, no apk add
 *   TEST 3: minor derivation default (no SINGBOX_FEED_MINOR, no os-release)
 *   TEST 4: real apk add target — selected core + UI, extended feed kept
 *   TEST 5: official core → core feed removed (feed on demand)
 *   TEST 6: invalid SINGBOX_CORE aborts non-zero, no apk add
 *   TEST 7: no-tty without SINGBOX_CORE falls back to default core
 *   TEST 8: pkg_version digit-anchoring — sing-box query does not match siblings
 */

import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

const ROOT = resolve(import.meta.dirname, "../..");
const INSTALL_SH = resolve(ROOT, "install.sh");

const PAGES_URL = "http://example.test/feed";

// Shared temp dir + stub binaries — set up once for the whole describe block
let TMP: string;
let BIN: string;
let ARCHFILE: string;
let KEYS_DIR: string;
let REPO_DIR: string;
let LIST: string;
let origPath: string;
let stubEnv: NodeJS.ProcessEnv;

beforeAll(() => {
  TMP = mkdtempSync(resolve(tmpdir(), "install-sh-"));
  BIN = resolve(TMP, "bin");
  ARCHFILE = resolve(TMP, "arch");
  KEYS_DIR = resolve(TMP, "keys");
  REPO_DIR = resolve(TMP, "repos");
  LIST = resolve(REPO_DIR, "luci-singbox.list");
  origPath = process.env.PATH ?? "";
  mkdirSync(BIN, { recursive: true });

  // --- apk stub ---
  // --print-arch → cat $ARCHFILE; update → no-op; list → fake version; add → record to apk.log
  writeFileSync(
    resolve(BIN, "apk"),
    `#!/bin/sh
case "$1" in
  --print-arch) cat "${ARCHFILE}" ;;
  update) : ;;
  list) shift; echo "$1-1.99.0-r1 x86_64 {$1} (GPL-3.0) [available]" ;;
  info) shift; case " \${STUB_INSTALLED:-} " in *" $1 "*) exit 0 ;; *) exit 1 ;; esac ;;
  add) shift; echo "apk add $*" >> "${TMP}/apk.log" ;;
  del) shift; echo "apk del $*" >> "${TMP}/apk.log" ;;
  *) : ;;
esac
`,
    { mode: 0o755 },
  );

  // --- wget stub ---
  // busybox form: wget -q -O <out> <url>  (records URL, writes placeholder)
  writeFileSync(
    resolve(BIN, "wget"),
    `#!/bin/sh
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -O) out="$2"; shift 2 ;; -q|-nv) shift ;; *) url="$1"; shift ;; esac; done
echo "$url" >> "${TMP}/wget.log"
[ -n "$out" ] && echo "PLACEHOLDER-KEY" > "$out"
exit 0
`,
    { mode: 0o755 },
  );

  // --- id stub --- (pretend root)
  writeFileSync(resolve(BIN, "id"), "#!/bin/sh\necho 0\n", { mode: 0o755 });

  stubEnv = {
    ...process.env,
    PATH: `${BIN}:${origPath}`,
    PAGES_URL,
    APK_KEYS_DIR: KEYS_DIR,
    APK_REPO_DIR: REPO_DIR,
  };
});

afterAll(() => {
  rmSync(TMP, { recursive: true, force: true });
});

/** Run install.sh with SINGBOX_INSTALL_TEST=1 and the given arch. */
function runInstall(arch: string, extraEnv: Record<string, string> = {}) {
  writeFileSync(ARCHFILE, `${arch}\n`);
  return spawnSync("sh", [INSTALL_SH], {
    encoding: "utf8",
    env: {
      ...stubEnv,
      SINGBOX_INSTALL_TEST: "1",
      SINGBOX_FEED_MINOR: "25.12",
      ...extraEnv,
    },
  });
}

function resetLogs() {
  writeFileSync(resolve(TMP, "wget.log"), "");
  writeFileSync(resolve(TMP, "apk.log"), "");
  rmSync(KEYS_DIR, { recursive: true, force: true });
  rmSync(REPO_DIR, { recursive: true, force: true });
}

function apkLog(): string {
  const p = resolve(TMP, "apk.log");
  return existsSync(p) ? readFileSync(p, "utf8") : "";
}
function wgetLog(): string {
  const p = resolve(TMP, "wget.log");
  return existsSync(p) ? readFileSync(p, "utf8") : "";
}

describe("install_sh", () => {
  it("TEST 1: happy path (x86_64) — key fetched, repo list written, no apk add", () => {
    resetLogs();
    const r = runInstall("x86_64");
    expect(r.status).toBe(0);

    // (a) signing key was fetched
    expect(wgetLog()).toContain(`${PAGES_URL}/luci-singbox.pem`);
    const keyFile = resolve(KEYS_DIR, "luci-singbox.pem");
    expect(existsSync(keyFile)).toBe(true);
    expect(statSync(keyFile).size).toBeGreaterThan(0);

    // (b) repo-list line = <PAGES_URL>/<minor>/<arch>/luci-singbox/packages.adb
    expect(existsSync(LIST)).toBe(true);
    const want = `${PAGES_URL}/25.12/x86_64/luci-singbox/packages.adb`;
    expect(readFileSync(LIST, "utf8").trim()).toBe(want);

    // SINGBOX_INSTALL_TEST=1 must NOT run apk add
    expect(apkLog()).toBe("");
  });

  it("TEST 2: unsupported arch aborts non-zero, no repo list, no apk add", () => {
    resetLogs();
    const r = runInstall("ppc64");
    expect(r.status).not.toBe(0);
    expect((r.stdout + r.stderr).toLowerCase()).toMatch(/unsupported/);
    expect(existsSync(LIST)).toBe(false);
    expect(apkLog()).toBe("");
  });

  it("TEST 3: minor derivation default (no SINGBOX_FEED_MINOR, no os-release)", () => {
    resetLogs();
    writeFileSync(ARCHFILE, "aarch64_generic\n");
    // No SINGBOX_FEED_MINOR; no /etc/os-release available in stub env
    const r = spawnSync("sh", [INSTALL_SH], {
      encoding: "utf8",
      env: {
        ...stubEnv,
        SINGBOX_INSTALL_TEST: "1",
        // deliberately omit SINGBOX_FEED_MINOR
      },
    });
    expect(r.status).toBe(0);
    expect(existsSync(LIST)).toBe(true);
    const got = readFileSync(LIST, "utf8").trim();
    // Must match: <PAGES_URL>/<something>/aarch64_generic/luci-singbox/packages.adb
    expect(got).toMatch(
      new RegExp(
        `^${PAGES_URL.replace(/[.]/g, "\\.")}/[^/]+/aarch64_generic/luci-singbox/packages\\.adb$`,
      ),
    );
  });

  it("TEST 4: real apk add target — selected core + UI, extended feed kept", () => {
    resetLogs();
    writeFileSync(ARCHFILE, "x86_64\n");
    const r = spawnSync("sh", [INSTALL_SH], {
      encoding: "utf8",
      env: {
        ...stubEnv,
        SINGBOX_FEED_MINOR: "25.12",
        SINGBOX_CORE: "sing-box-extended-upx",
        // No SINGBOX_INSTALL_TEST
      },
    });
    expect(r.status).toBe(0);
    expect(apkLog().trim()).toBe(
      "apk add sing-box-extended-upx luci-app-singbox-ui luci-i18n-singbox-ui-ru",
    );
    // extended core → core feed list kept
    expect(existsSync(resolve(REPO_DIR, "singbox-core.list"))).toBe(true);
  });

  it("TEST 5: official core → core feed removed (feed on demand)", () => {
    resetLogs();
    writeFileSync(ARCHFILE, "x86_64\n");
    const r = spawnSync("sh", [INSTALL_SH], {
      encoding: "utf8",
      env: {
        ...stubEnv,
        SINGBOX_FEED_MINOR: "25.12",
        SINGBOX_CORE: "sing-box",
      },
    });
    expect(r.status).toBe(0);
    expect(apkLog().trim()).toBe(
      "apk add sing-box luci-app-singbox-ui luci-i18n-singbox-ui-ru",
    );
    expect(existsSync(resolve(REPO_DIR, "singbox-core.list"))).toBe(false);
  });

  it("TEST 4b: core swap removes the old core in the SAME apk add (no standalone apk del)", () => {
    resetLogs();
    writeFileSync(ARCHFILE, "x86_64\n");
    const r = spawnSync("sh", [INSTALL_SH], {
      encoding: "utf8",
      env: {
        ...stubEnv,
        SINGBOX_FEED_MINOR: "25.12",
        SINGBOX_CORE: "sing-box-extended-upx",
        STUB_INSTALLED: "sing-box-extended", // an old conflicting core is installed
      },
    });
    expect(r.status).toBe(0);
    const log = apkLog();
    // The old core is removed via a !conflict folded into the single apk add,
    // never a standalone `apk del` (which would break singbox-ui's sing-box dep).
    expect(log).not.toContain("apk del");
    expect(log.trim()).toBe(
      "apk add sing-box-extended-upx !sing-box-extended luci-app-singbox-ui luci-i18n-singbox-ui-ru",
    );
  });

  it("TEST 4c: swapping to plain sing-box never emits a bare !sing-box (provided-virtual trap)", () => {
    resetLogs();
    writeFileSync(ARCHFILE, "x86_64\n");
    const r = spawnSync("sh", [INSTALL_SH], {
      encoding: "utf8",
      env: {
        ...stubEnv,
        SINGBOX_FEED_MINOR: "25.12",
        SINGBOX_CORE: "sing-box",
        STUB_INSTALLED: "sing-box-extended sing-box-extended-upx",
      },
    });
    expect(r.status).toBe(0);
    const log = apkLog();
    expect(log).not.toContain("apk del");
    expect(log).not.toContain("!sing-box "); // bare !sing-box would conflict the new core's provide
    expect(log.trim()).toBe(
      "apk add sing-box !sing-box-extended !sing-box-extended-upx luci-app-singbox-ui luci-i18n-singbox-ui-ru",
    );
  });

  it("TEST 6: invalid SINGBOX_CORE aborts non-zero, no apk add", () => {
    resetLogs();
    writeFileSync(ARCHFILE, "x86_64\n");
    const r = spawnSync("sh", [INSTALL_SH], {
      encoding: "utf8",
      env: {
        ...stubEnv,
        SINGBOX_FEED_MINOR: "25.12",
        SINGBOX_CORE: "bogus",
      },
    });
    expect(r.status).not.toBe(0);
    expect((r.stdout + r.stderr).toLowerCase()).toMatch(/unknown/);
    expect(apkLog()).toBe("");
  });

  it("TEST 7: no-tty without SINGBOX_CORE falls back to default core", () => {
    resetLogs();
    writeFileSync(ARCHFILE, "x86_64\n");
    // No SINGBOX_CORE and no SINGBOX_INSTALL_TEST: choose_core must detect the
    // absence of a controlling terminal (/dev/tty unreadable in a spawned process)
    // and fall back to SINGBOX_CORE_DEFAULT = sing-box-extended-upx.
    const r = spawnSync("sh", [INSTALL_SH], {
      encoding: "utf8",
      env: { ...stubEnv, SINGBOX_FEED_MINOR: "25.12" },
    });
    expect(r.status).toBe(0);
    expect(apkLog().trim()).toBe(
      "apk add sing-box-extended-upx luci-app-singbox-ui luci-i18n-singbox-ui-ru",
    );
    // extended core → core feed list kept
    expect(existsSync(resolve(REPO_DIR, "singbox-core.list"))).toBe(true);
  });

  it("TEST 8: pkg_version digit-anchoring — sing-box query does not match siblings", () => {
    // Extract the pkg_version function from install.sh and run it under sh with
    // a custom apk stub so we can prove the digit-anchor case "$tok" in "$1"-[0-9]*)
    // rejects sibling packages like sing-box-extended-* when querying sing-box.
    const src = readFileSync(INSTALL_SH, "utf8");
    const pkgVersionFn = src.match(/^pkg_version\(\)\s*\{[\s\S]*?^\}/m)?.[0];
    expect(pkgVersionFn).toBeTruthy();

    // Fresh temp dir so we don't touch the shared BIN/stubEnv used by TESTs 1-7.
    const t8tmp = mkdtempSync(resolve(tmpdir(), "install-sh-t8-"));
    const t8bin = resolve(t8tmp, "bin");
    mkdirSync(t8bin, { recursive: true });

    // apk stub: for `apk list sing-box` emit ONLY sibling lines (no bare sing-box-<digit>);
    // for any other name emit a normal <name>-<ver> line.
    writeFileSync(
      resolve(t8bin, "apk"),
      `#!/bin/sh
case "$1" in
  list) shift
    case "$1" in
      sing-box) printf '%s\\n' "sing-box-extended-1.13.0_p2.4.1 x86_64 {sing-box-extended} (GPL-3.0) [available]" "sing-box-extended-upx-1.13.0_p2.4.1 x86_64 {sing-box-extended-upx} (GPL-3.0) [available]" ;;
      *) echo "$1-1.13.0_p2.4.1 x86_64 {$1} (GPL-3.0) [available]" ;;
    esac ;;
  *) : ;;
esac
`,
      { mode: 0o755 },
    );

    function pkgVersion(pkg: string, binDir: string): string {
      const r = spawnSync(
        "sh",
        ["-c", `${pkgVersionFn}\npkg_version "$1"`, "sh", pkg],
        {
          encoding: "utf8",
          env: { ...process.env, PATH: `${binDir}:${process.env.PATH ?? ""}` },
        },
      );
      return (r.stdout ?? "").trim();
    }

    try {
      // sing-box query must NOT match sing-box-extended-* lines — anchor rejects them
      expect(pkgVersion("sing-box", t8bin)).toBe("");
      // sing-box-extended query must match its own line
      expect(pkgVersion("sing-box-extended", t8bin)).toBe("1.13.0_p2.4.1");
      // sing-box-extended-upx query must match its own line
      expect(pkgVersion("sing-box-extended-upx", t8bin)).toBe("1.13.0_p2.4.1");
    } finally {
      rmSync(t8tmp, { recursive: true, force: true });
    }
  });
});
