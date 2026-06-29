/**
 * tests/cross/install_manifest_fresh.test.ts
 * Port of tests/cross/test_install_manifest_fresh.sh
 *
 * Verifies the per-package install manifests are in sync with what
 * gen-manifest.sh would produce — catches drift between manual edits and
 * auto-generation.
 *
 * gen-manifest.sh pins LC_ALL=C sort internally; we compare byte-for-byte
 * so no locale override is needed here.
 *
 * Also enforces D4.5: exactly two files under lib/plugins/ in the backend
 * manifest — plugins/registry.uc + plugins/discovery.uc.
 */

import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

const ROOT = resolve(import.meta.dirname, "../..");
const GEN_SH = resolve(ROOT, "scripts/gen-manifest.sh");

const MANIFESTS = [
  "scripts/install-manifest-singbox-ui.txt",
  "scripts/install-manifest-luci-app-singbox-ui.txt",
];

describe("install_manifest_fresh", () => {
  it("manifests are in sync with gen-manifest.sh output", () => {
    // Snapshot the committed manifests before regeneration
    const tmpdir2 = mkdtempSync(resolve(tmpdir(), "manifest-fresh-"));
    const snapshots: Record<string, string> = {};
    for (const m of MANIFESTS) {
      const abs = resolve(ROOT, m);
      snapshots[m] = readFileSync(abs, "utf8");
    }

    try {
      // Regenerate. gen-manifest.sh pins LC_ALL=C sort internally.
      const _r = spawnSync("sh", [GEN_SH], {
        cwd: ROOT,
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
      });
      // Tolerate non-zero only if it printed something useful; most errors exit 0
      // (gen-manifest.sh writes to the files, doesn't need to exit 0 to succeed)

      let stale = false;
      for (const m of MANIFESTS) {
        const abs = resolve(ROOT, m);
        const after = readFileSync(abs, "utf8");
        if (after !== snapshots[m]) {
          stale = true;
          console.error(`FAIL: ${m} is stale. Run: sh scripts/gen-manifest.sh`);
          // Restore so the test doesn't dirty the working tree
          writeFileSync(abs, snapshots[m]);
        }
      }
      expect(stale).toBe(false);
    } finally {
      // Always restore in case of unexpected error
      for (const m of MANIFESTS) {
        const abs = resolve(ROOT, m);
        const current = existsSync(abs) ? readFileSync(abs, "utf8") : "";
        if (current !== snapshots[m]) {
          writeFileSync(abs, snapshots[m]);
        }
      }
      rmSync(tmpdir2, { recursive: true, force: true });
    }
  });

  it("D4.5/E: core ships only plugin INFRASTRUCTURE under lib/plugins/ (registry.uc + discovery.uc); no plugin payloads", () => {
    // Phase E: the framework adds discovery.uc alongside registry.uc. These are
    // the only two files the CORE backend package ships under lib/plugins/.
    // Actual plugins ship their own lib/plugins/<name>/ subtree from their own
    // package (e.g. singbox-ui-plugin-awg_warp), never from core.
    const be = resolve(ROOT, "scripts/install-manifest-singbox-ui.txt");
    const lines = readFileSync(be, "utf8").split("\n");
    const pluginLines = lines
      .filter((l) => l.startsWith("root/usr/share/singbox-ui/lib/plugins/"))
      .map((l) => l.split("\t")[0]);
    const expected = [
      "root/usr/share/singbox-ui/lib/plugins/discovery.uc",
      "root/usr/share/singbox-ui/lib/plugins/registry.uc",
    ];
    expect(pluginLines.sort()).toEqual(expected);
  });
});
