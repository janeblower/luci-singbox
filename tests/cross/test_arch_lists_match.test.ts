import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

// The covered-arch list lives in two shell scripts that must agree: install.sh
// decides which arches the installer accepts, build-feed.sh decides which arch
// directories the feed actually publishes. They were kept in sync by a comment.
// A drift is silent and asymmetric — the installer would either reject an arch
// the feed carries, or accept one it does not (and 404 at `apk add`).
const ROOT = resolve(import.meta.dirname, "../..");

function shellList(file: string, varName: string): string[] {
  const src = readFileSync(resolve(ROOT, file), "utf8");
  const m = src.match(new RegExp(`^${varName}="([^"]*)"`, "m"));
  if (!m) throw new Error(`${varName} not found in ${file}`);
  return m[1].split(/\s+/).filter(Boolean);
}

describe("covered arch lists", () => {
  it("install.sh COVERED == build-feed.sh COVERED_ARCHES", () => {
    const installer = shellList("install.sh", "COVERED");
    const feed = shellList("scripts/build-feed.sh", "COVERED_ARCHES");

    expect(installer.length).toBeGreaterThan(0);
    // Same set AND same order — the scripts iterate them, so a reorder is
    // harmless but a diff in either direction is what we are guarding.
    expect([...installer].sort()).toEqual([...feed].sort());
  });
});
