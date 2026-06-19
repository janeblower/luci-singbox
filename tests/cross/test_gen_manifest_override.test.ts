/**
 * tests/cross/gen_manifest_override.test.ts
 * Port of tests/cross/test_gen_manifest_override.sh
 *
 * Black-box behavioral regression for S5-8: gen-manifest.sh must match
 * override rows by EXACT source path, never as a regex. A path with a
 * metacharacter (e.g. `a.b`) must not steal the override of a different
 * sibling (`aXb`) and vice-versa.
 *
 * Drives the REAL script against a throwaway tree via PKG/OUT/OVERRIDES
 * env hooks.
 */
import { describe, expect, it } from "bun:test";
import { spawnSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";

const ROOT = resolve(import.meta.dir, "../..");
const GEN_SH = resolve(ROOT, "scripts/gen-manifest.sh");

describe("gen_manifest_override", () => {
  it("override src matched as exact fixed string, not regex ('a.b' must not match 'aXb')", () => {
    const td = mkdtempSync(resolve(tmpdir(), "gen-manifest-ovr-"));
    try {
      // Two sibling files differing only by the char a regex '.' would conflate
      const pkgDir = resolve(td, "pkg");
      mkdirSync(resolve(pkgDir, "root/etc/config"), { recursive: true });
      writeFileSync(resolve(pkgDir, "root/etc/config/a.b"), "");
      writeFileSync(resolve(pkgDir, "root/etc/config/aXb"), "");

      // Override targets ONLY a.b; as a regex '^root/etc/config/a.b<TAB>'
      // would also match 'root/etc/config/aXb' (the bug)
      const ovr = resolve(td, "overrides.txt");
      writeFileSync(ovr, "root/etc/config/a.b\tHIT_AB\tdata\n");

      const out = resolve(td, "manifest.txt");
      const _r = spawnSync("sh", [GEN_SH], {
        cwd: ROOT,
        encoding: "utf8",
        env: {
          ...process.env,
          PKG: pkgDir,
          OUT: out,
          OVERRIDES: ovr,
        },
      });
      // gen-manifest.sh may exit non-zero for minor reasons; only care about output
      const manifest = readFileSync(out, "utf8");

      // a.b MUST take the override (dst = HIT_AB sentinel)
      expect(manifest).toMatch(/^root\/etc\/config\/a\.b\tHIT_AB\tdata$/m);

      // aXb MUST NOT have been hit by a.b's override — keeps generated dst
      expect(manifest).not.toMatch(/^root\/etc\/config\/aXb\tHIT_AB/m);

      // aXb MUST have its own generated row (dst = etc/config/aXb, mode = conf)
      expect(manifest).toMatch(
        /^root\/etc\/config\/aXb\tetc\/config\/aXb\tconf$/m,
      );
    } finally {
      rmSync(td, { recursive: true, force: true });
    }
  });
});
