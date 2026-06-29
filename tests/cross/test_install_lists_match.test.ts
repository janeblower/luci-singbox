/**
 * tests/cross/install_lists_match.test.ts
 * Port of tests/cross/test_install_lists_match.sh
 *
 * Architectural invariant: each package's install manifest is the SINGLE source
 * of truth for its install file set. Both the buildroot Makefile and
 * scripts/build-apk.sh must consume it.
 *
 * For each package asserts:
 *   1. Manifest file exists and is non-empty.
 *   2. Both builders reference it (Makefile while-read loop + build-apk.sh).
 *   3. Every non-comment row is a 3-field TSV (src, dst, mode).
 *   4. Every src listed exists in that package's source tree.
 *   5. Every mode is one of bin|conf|data.
 *   6. Every shippable file under the coverage dirs is covered by the manifest.
 */

import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { relative, resolve } from "node:path";
import { describe, expect, it } from "vitest";

const ROOT = resolve(import.meta.dirname, "../..");
const BUILDSH = resolve(ROOT, "scripts/build-apk.sh");

/** Recursively list all files under dir. Returns paths relative to ROOT. */
function listFilesRecursive(dir: string): string[] {
  const result: string[] = [];
  function walk(d: string) {
    for (const entry of readdirSync(d, { withFileTypes: true })) {
      const full = resolve(d, entry.name);
      if (entry.isDirectory()) {
        walk(full);
      } else if (entry.isFile() || entry.isSymbolicLink()) {
        result.push(relative(ROOT, full));
      }
    }
  }
  if (existsSync(dir)) walk(dir);
  return result;
}

/** Parse a manifest file. Returns the data rows (skips comments + blank). */
function parseManifest(
  manifest: string,
): Array<{ src: string; dst: string; mode: string; raw: string }> {
  const rows: Array<{ src: string; dst: string; mode: string; raw: string }> =
    [];
  for (const line of readFileSync(manifest, "utf8").split("\n")) {
    const trimmed = line.trimStart();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const parts = line.split("\t");
    rows.push({
      src: parts[0] ?? "",
      dst: parts[1] ?? "",
      mode: parts[2] ?? "",
      raw: line,
    });
  }
  return rows;
}

interface PkgSpec {
  label: string;
  srcDir: string; // relative to ROOT (for display)
  manifest: string; // absolute
  makefile: string; // absolute
  coverageDirs: string[]; // absolute paths
}

const PKGS: PkgSpec[] = [
  {
    label: "backend (singbox-ui)",
    srcDir: "singbox-ui",
    manifest: resolve(ROOT, "scripts/install-manifest-singbox-ui.txt"),
    makefile: resolve(ROOT, "singbox-ui/Makefile"),
    coverageDirs: [resolve(ROOT, "singbox-ui/root")],
  },
  {
    label: "frontend (luci-app-singbox-ui)",
    srcDir: "luci-app-singbox-ui",
    manifest: resolve(ROOT, "scripts/install-manifest-luci-app-singbox-ui.txt"),
    makefile: resolve(ROOT, "luci-app-singbox-ui/Makefile"),
    // po/ is compiled by po2lmo separately — NOT a coverage dir
    coverageDirs: [
      resolve(ROOT, "luci-app-singbox-ui/htdocs"),
      resolve(ROOT, "luci-app-singbox-ui/root"),
    ],
  },
];

const buildShExists = existsSync(BUILDSH);

describe("install_lists_match", () => {
  it("scripts/build-apk.sh exists", () => {
    expect(buildShExists).toBe(true);
  });

  for (const pkg of PKGS) {
    describe(pkg.label, () => {
      it("1. manifest file exists and is non-empty", () => {
        expect(existsSync(pkg.manifest)).toBe(true);
        expect(statSync(pkg.manifest).size).toBeGreaterThan(0);
      });

      it("2. both builders reference the manifest (Makefile while-read loop + build-apk.sh)", () => {
        const manBase = require("node:path").basename(pkg.manifest);
        const makefileContent = readFileSync(pkg.makefile, "utf8");
        const buildShContent = readFileSync(BUILDSH, "utf8");

        // Makefile must reference the manifest by name
        expect(makefileContent).toContain(manBase);
        // Makefile must have a manifest-driven install loop
        expect(makefileContent).toMatch(/while .*read .*src .*dst .*mode/);
        // build-apk.sh must reference the manifest by name
        expect(buildShContent).toContain(manBase);
      });

      it("3. every non-comment row is a 3-field TSV (src, dst, mode)", () => {
        const rows = parseManifest(pkg.manifest);
        for (const row of rows) {
          const fieldsOk = row.src !== "" && row.dst !== "" && row.mode !== "";
          // Also check no extra tab-separated fields
          const parts = row.raw.split("\t");
          expect(fieldsOk && parts.length === 3).toBe(true);
        }
      });

      it("4. every src listed exists in the source tree", () => {
        const rows = parseManifest(pkg.manifest);
        const srcDir = resolve(ROOT, pkg.srcDir);
        for (const row of rows) {
          const fullSrc = resolve(srcDir, row.src);
          expect(existsSync(fullSrc)).toBe(true);
        }
      });

      it("5. every mode is one of bin|conf|data", () => {
        const rows = parseManifest(pkg.manifest);
        const valid = new Set(["bin", "conf", "data"]);
        for (const row of rows) {
          expect(valid.has(row.mode)).toBe(true);
        }
      });

      it("6. every shippable file under coverage dirs is covered by the manifest", () => {
        const srcDir = resolve(ROOT, pkg.srcDir);
        const rows = parseManifest(pkg.manifest);
        // Build a set of listed src paths (relative to the package src dir)
        const listed = new Set(rows.map((r) => r.src));

        const missing: string[] = [];
        for (const covDir of pkg.coverageDirs) {
          const treeFiles = listFilesRecursive(covDir);
          // sed "s#^$src_dir/##" — strip the package src dir prefix
          for (const f of treeFiles) {
            // f is relative to ROOT; make it relative to srcDir
            const rel = relative(srcDir, resolve(ROOT, f));
            if (!listed.has(rel)) {
              missing.push(rel);
            }
          }
        }
        expect(missing).toEqual([]);
      });
    });
  }
});
