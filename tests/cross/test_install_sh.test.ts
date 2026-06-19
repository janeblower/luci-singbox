/**
 * tests/cross/install_sh.test.ts
 * Port of tests/cross/test_install_sh.sh
 *
 * Unit test for the FEED-based install.sh. Drives the flow WITHOUT network:
 * stubs `apk` (--print-arch / update / add) and `wget` via PATH + temp dir;
 * redirects /etc/apk/... root paths via APK_KEYS_DIR / APK_REPO_DIR env hooks.
 *
 * Four tests:
 *   TEST 1: happy path (x86_64) — key fetched, repo list written, no apk add
 *   TEST 2: unsupported arch aborts non-zero, no repo list, no apk add
 *   TEST 3: minor derivation default (no SINGBOX_FEED_MINOR, no os-release)
 *   TEST 4: real apk add target (drop SINGBOX_INSTALL_TEST so apk add runs)
 */
import { afterAll, beforeAll, describe, expect, it } from "bun:test";
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

const ROOT = resolve(import.meta.dir, "../..");
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
  // --print-arch → cat $ARCHFILE; update → no-op; add → record to apk.log
  writeFileSync(
    resolve(BIN, "apk"),
    `#!/bin/sh
case "$1" in
  --print-arch) cat "${ARCHFILE}" ;;
  update) : ;;
  add) shift; echo "apk add $*" >> "${TMP}/apk.log" ;;
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

  it("TEST 4: real apk add target (no SINGBOX_INSTALL_TEST → apk add runs)", () => {
    resetLogs();
    writeFileSync(ARCHFILE, "x86_64\n");
    const r = spawnSync("sh", [INSTALL_SH], {
      encoding: "utf8",
      env: {
        ...stubEnv,
        SINGBOX_FEED_MINOR: "25.12",
        // No SINGBOX_INSTALL_TEST
      },
    });
    expect(r.status).toBe(0);
    // apk add luci-app-singbox-ui luci-i18n-singbox-ui-ru
    expect(apkLog().trim()).toBe(
      "apk add luci-app-singbox-ui luci-i18n-singbox-ui-ru",
    );
  });
});
