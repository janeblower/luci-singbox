import { describe, expect, it } from "bun:test";
import { existsSync, readFileSync } from "node:fs";

// Port of tests/backend/test_openwrt_version_sync.sh
// Single-source-of-truth guard: every OpenWrt version reference across the
// repo must equal tests/docker/openwrt-version.txt.
// Host-only file parsing — no guest needed.

const VF = "tests/docker/openwrt-version.txt";

// Files that reference an OpenWrt version literal and MUST match canonical.
// (Dockerfile is excluded — it interpolates the ARG; verified by test_openwrt_version_file.sh)
const CHECK = [
  ".github/workflows/build.yml",
  ".github/workflows/pages.yml",
  ".github/workflows/test-image.yml",
  "scripts/build-apk.sh",
  "tests/browser-container/Dockerfile",
  "tests/browser-container/entrypoint.sh",
];

// Mirror the shell logic:
//   grep lines with 'openwrt'
//   extract tokens matching [A-Za-z._/-]*[0-9]+\.[0-9]+\.[0-9]+
//   drop tokens immediately preceded by "gcc-"
//   keep only the numeric X.Y.Z suffix
//   reject any that don't equal VER
function extractBadVersions(content: string, ver: string): string[] {
  const bad: string[] = [];
  for (const line of content.split("\n")) {
    if (!/openwrt/.test(line)) continue;
    // Extract version-like tokens (X.Y.Z) from the line
    const tokens = line.match(/[A-Za-z._/-]*[0-9]+\.[0-9]+\.[0-9]+/g) ?? [];
    for (const tok of tokens) {
      // Skip gcc toolchain versions (immediately preceded by "gcc-")
      if (/gcc-[0-9]/.test(tok)) continue;
      // Extract trailing X.Y.Z numeric part
      const m = tok.match(/([0-9]+\.[0-9]+\.[0-9]+)$/);
      if (!m) continue;
      const v = m[1];
      if (v !== ver) bad.push(v);
    }
  }
  return bad;
}

describe("openwrt version sync", () => {
  it("version file exists and is non-empty", () => {
    expect(existsSync(VF)).toBe(true);
    const ver = readFileSync(VF, "utf8").trim();
    expect(ver.length).toBeGreaterThan(0);
  });

  const ver = existsSync(VF) ? readFileSync(VF, "utf8").trim() : "";

  for (const f of CHECK) {
    it(`${f} references only version ${ver || "<unknown>"}`, () => {
      expect(ver.length).toBeGreaterThan(0);
      expect(existsSync(f)).toBe(true);
      const content = readFileSync(f, "utf8");
      const bad = extractBadVersions(content, ver);
      expect(bad).toEqual([]);
    });
  }
});
