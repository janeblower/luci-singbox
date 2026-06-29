/**
 * tests/cross/test_publish_feed.test.ts
 *
 * Regression guard for scripts/publish-feed.sh — the gh-pages publisher that
 * replaced peaceiris/actions-gh-pages keep_files:true (pages.yml). The bug it
 * fixes: keep_files merges and NEVER deletes, so every past package version's
 * .apk accumulated in gh-pages forever. publish-feed.sh must instead wipe the
 * directories THIS feed owns (<ver>/<arch>/luci-singbox/) so only the current
 * version survives — WITHOUT touching the sibling sing-box-extended core feeds
 * (<ver>/<arch>/sing-box/), published independently by sing-box-extended.yml.
 *
 * Runs through the real script against a local git remote (no apk/network).
 * Host-only (tests/cross never runs in the qemu VM); needs git on PATH.
 */

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
import { describe, expect, it } from "vitest";

const ROOT = resolve(import.meta.dirname, "../..");
const SCRIPT = resolve(ROOT, "scripts/publish-feed.sh");

const hasGit =
  spawnSync("git", ["--version"], { encoding: "utf8" }).status === 0;

// Deterministic identity for the seed commits (the script sets its own).
const GIT_ENV = {
  ...process.env,
  GIT_AUTHOR_NAME: "t",
  GIT_AUTHOR_EMAIL: "t@t",
  GIT_COMMITTER_NAME: "t",
  GIT_COMMITTER_EMAIL: "t@t",
  GIT_CONFIG_GLOBAL: "/dev/null",
  GIT_CONFIG_SYSTEM: "/dev/null",
};

function git(cwd: string, ...args: string[]): void {
  const r = spawnSync("git", args, { cwd, encoding: "utf8", env: GIT_ENV });
  if (r.status !== 0) {
    throw new Error(`git ${args.join(" ")} failed:\n${r.stderr}\n${r.stdout}`);
  }
}

function write(path: string, content: string): void {
  mkdirSync(resolve(path, ".."), { recursive: true });
  writeFileSync(path, content);
}

describe("publish_feed", () => {
  it.skipIf(!hasGit)(
    "deletes stale owned-dir apks, preserves sibling sing-box subtree",
    () => {
      const base = mkdtempSync(resolve(tmpdir(), "publish-feed-"));
      try {
        const remote = resolve(base, "remote.git");
        const seed = resolve(base, "seed");
        const pub = resolve(base, "public");
        const work = resolve(base, "work");

        // --- Bare "remote" with an initial gh-pages branch ------------------
        git(base, "init", "--bare", remote);

        // Seed gh-pages with: an OLD version of our feed (r1) AND a sibling
        // sing-box core feed that must survive every deploy untouched.
        mkdirSync(seed, { recursive: true });
        git(seed, "init", "-b", "gh-pages");
        const sLuci = resolve(seed, "25.12/x86_64/luci-singbox");
        write(resolve(sLuci, "luci-app-singbox-ui-0.0.0-r1.apk"), "old-app\n");
        write(resolve(sLuci, "bbolt-client-0.0.0-r1.apk"), "old-bbolt\n");
        write(resolve(sLuci, "packages.adb"), "old-index\n");
        write(resolve(sLuci, "index.md"), "old\n");
        const sCore = resolve(seed, "25.12/x86_64/sing-box");
        write(resolve(sCore, "sing-box-extended-1.13.0-r1.apk"), "core\n");
        write(resolve(sCore, "packages.adb"), "core-index\n");
        write(resolve(seed, "25.12/x86_64/index.md"), "arch-old\n");
        write(resolve(seed, "_config.yml"), "old-config\n");
        write(resolve(seed, "luci-singbox.pem"), "KEY\n");
        git(seed, "add", "-A");
        git(seed, "commit", "-m", "seed");
        git(seed, "remote", "add", "origin", remote);
        git(seed, "push", "origin", "gh-pages");

        // --- Freshly built "public" tree: NEW version (r2) only ------------
        const pLuci = resolve(pub, "25.12/x86_64/luci-singbox");
        write(resolve(pLuci, "luci-app-singbox-ui-0.0.0-r2.apk"), "new-app\n");
        write(resolve(pLuci, "bbolt-client-0.0.0-r2.apk"), "new-bbolt\n");
        write(resolve(pLuci, "packages.adb"), "new-index\n");
        write(resolve(pLuci, "index.md"), "new\n");
        write(resolve(pub, "25.12/x86_64/index.md"), "arch-new\n");
        write(resolve(pub, "_config.yml"), "new-config\n");
        write(resolve(pub, "luci-singbox.pem"), "KEY\n");

        // --- Run the real script ------------------------------------------
        const r = spawnSync("sh", [SCRIPT, pub], {
          cwd: base,
          encoding: "utf8",
          env: {
            ...GIT_ENV,
            FEED_GIT_REMOTE: remote,
            FEED_WORK: work,
            FEED_COMMIT_MSG: "deploy feed: testsha",
          },
        });
        expect(r.stderr + r.stdout).toContain("published feed to gh-pages");
        expect(r.status).toBe(0);

        // --- Verify the published branch ----------------------------------
        const verify = resolve(base, "verify");
        git(base, "clone", "--branch", "gh-pages", remote, verify);

        const vLuci = resolve(verify, "25.12/x86_64/luci-singbox");
        const apks = readdirSync(vLuci)
          .filter((f) => f.endsWith(".apk"))
          .sort();
        // Stale r1 apks are GONE; only the current r2 apks remain.
        expect(apks).toEqual([
          "bbolt-client-0.0.0-r2.apk",
          "luci-app-singbox-ui-0.0.0-r2.apk",
        ]);
        expect(
          existsSync(resolve(vLuci, "luci-app-singbox-ui-0.0.0-r1.apk")),
        ).toBe(false);

        // Sibling sing-box core feed is preserved byte-for-byte.
        const vCore = resolve(verify, "25.12/x86_64/sing-box");
        expect(
          existsSync(resolve(vCore, "sing-box-extended-1.13.0-r1.apk")),
        ).toBe(true);
        expect(existsSync(resolve(vCore, "packages.adb"))).toBe(true);

        // Regenerated files are overwritten with the new tree's content.
        expect(
          spawnSync("cat", [resolve(vLuci, "packages.adb")], {
            encoding: "utf8",
          }).stdout,
        ).toBe("new-index\n");

        // Commit subject carried through.
        const log = spawnSync(
          "git",
          ["-C", verify, "log", "-1", "--format=%s"],
          {
            encoding: "utf8",
            env: GIT_ENV,
          },
        ).stdout.trim();
        expect(log).toBe("deploy feed: testsha");
      } finally {
        rmSync(base, { recursive: true, force: true });
      }
    },
  );

  it.skipIf(!hasGit)(
    "no-op when the built tree matches gh-pages (nothing to commit)",
    () => {
      const base = mkdtempSync(resolve(tmpdir(), "publish-feed-noop-"));
      try {
        const remote = resolve(base, "remote.git");
        const seed = resolve(base, "seed");
        const pub = resolve(base, "public");

        git(base, "init", "--bare", remote);
        mkdirSync(seed, { recursive: true });
        git(seed, "init", "-b", "gh-pages");
        const sLuci = resolve(seed, "25.12/x86_64/luci-singbox");
        write(resolve(sLuci, "bbolt-client-0.0.0-r2.apk"), "same\n");
        write(resolve(sLuci, "packages.adb"), "same-index\n");
        git(seed, "add", "-A");
        git(seed, "commit", "-m", "seed");
        git(seed, "remote", "add", "origin", remote);
        git(seed, "push", "origin", "gh-pages");

        // public identical to what's on the branch.
        const pLuci = resolve(pub, "25.12/x86_64/luci-singbox");
        write(resolve(pLuci, "bbolt-client-0.0.0-r2.apk"), "same\n");
        write(resolve(pLuci, "packages.adb"), "same-index\n");

        const r = spawnSync("sh", [SCRIPT, pub], {
          cwd: base,
          encoding: "utf8",
          env: {
            ...GIT_ENV,
            FEED_GIT_REMOTE: remote,
            FEED_WORK: resolve(base, "work"),
          },
        });
        expect(r.status).toBe(0);
        expect(r.stdout + r.stderr).toContain("nothing to commit");
      } finally {
        rmSync(base, { recursive: true, force: true });
      }
    },
  );

  // Inverse ownership: sing-box-extended.yml reuses this same script with
  // FEED_OWNED_DIR=sing-box. It must wipe stale 25.12/<arch>/sing-box/*.apk while
  // leaving the sibling luci-singbox/ subtree (owned by the main feed) and the
  // shared browse pages untouched — the mirror image of the default case above.
  it.skipIf(!hasGit)(
    "FEED_OWNED_DIR=sing-box wipes stale core apks, preserves luci-singbox sibling",
    () => {
      const base = mkdtempSync(resolve(tmpdir(), "publish-feed-core-"));
      try {
        const remote = resolve(base, "remote.git");
        const seed = resolve(base, "seed");
        const pub = resolve(base, "public");
        const work = resolve(base, "work");

        git(base, "init", "--bare", remote);

        // Seed: an OLD sing-box core version, a sibling luci-singbox feed, and
        // shared browse pages — all of which (except the old core apk) survive.
        mkdirSync(seed, { recursive: true });
        git(seed, "init", "-b", "gh-pages");
        const sCore = resolve(seed, "25.12/x86_64/sing-box");
        write(
          resolve(sCore, "sing-box-extended-1.13.12_p002004001.apk"),
          "old\n",
        );
        write(
          resolve(sCore, "sing-box-extended-upx-1.13.12_p002004001.apk"),
          "old-upx\n",
        );
        write(resolve(sCore, "packages.adb"), "old-core-index\n");
        write(resolve(sCore, "index.md"), "old-core\n");
        const sLuci = resolve(seed, "25.12/x86_64/luci-singbox");
        write(resolve(sLuci, "luci-app-singbox-ui-0.0.0-r9.apk"), "app\n");
        write(resolve(sLuci, "packages.adb"), "app-index\n");
        write(resolve(seed, "25.12/x86_64/index.md"), "arch-page\n");
        write(resolve(seed, "luci-singbox.pem"), "KEY\n");
        git(seed, "add", "-A");
        git(seed, "commit", "-m", "seed");
        git(seed, "remote", "add", "origin", remote);
        git(seed, "push", "origin", "gh-pages");

        // Freshly built tree: NEW core version only (feed.sh output shape).
        const pCore = resolve(pub, "25.12/x86_64/sing-box");
        write(
          resolve(pCore, "sing-box-extended-1.13.14_p002005000.apk"),
          "new\n",
        );
        write(
          resolve(pCore, "sing-box-extended-upx-1.13.14_p002005000.apk"),
          "new-upx\n",
        );
        write(resolve(pCore, "packages.adb"), "new-core-index\n");
        write(resolve(pCore, "index.md"), "new-core\n");

        const r = spawnSync("sh", [SCRIPT, pub], {
          cwd: base,
          encoding: "utf8",
          env: {
            ...GIT_ENV,
            FEED_GIT_REMOTE: remote,
            FEED_OWNED_DIR: "sing-box",
            FEED_WORK: work,
            FEED_COMMIT_MSG: "deploy sing-box-extended feed: v1.13.14",
          },
        });
        expect(r.stderr + r.stdout).toContain("published feed to gh-pages");
        expect(r.status).toBe(0);

        const verify = resolve(base, "verify");
        git(base, "clone", "--branch", "gh-pages", remote, verify);

        // Stale 1.13.12 core apks are GONE; only the current 1.13.14 remain.
        const vCore = resolve(verify, "25.12/x86_64/sing-box");
        const coreApks = readdirSync(vCore)
          .filter((f) => f.endsWith(".apk"))
          .sort();
        expect(coreApks).toEqual([
          "sing-box-extended-1.13.14_p002005000.apk",
          "sing-box-extended-upx-1.13.14_p002005000.apk",
        ]);

        // Sibling luci-singbox feed + shared pages preserved byte-for-byte.
        const vLuci = resolve(verify, "25.12/x86_64/luci-singbox");
        expect(
          existsSync(resolve(vLuci, "luci-app-singbox-ui-0.0.0-r9.apk")),
        ).toBe(true);
        expect(existsSync(resolve(vLuci, "packages.adb"))).toBe(true);
        expect(existsSync(resolve(verify, "25.12/x86_64/index.md"))).toBe(true);
        expect(existsSync(resolve(verify, "luci-singbox.pem"))).toBe(true);
      } finally {
        rmSync(base, { recursive: true, force: true });
      }
    },
  );
});
