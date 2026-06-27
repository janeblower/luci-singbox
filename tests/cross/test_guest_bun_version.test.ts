import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

// Single-source guard: the guest musl-baseline bun must derive from the SAME
// BUN_VERSION that pins the host glibc bun, so the in-guest test runner and
// the host CI lanes (setup-bun) never drift.
const DOCKERFILE = resolve(import.meta.dir, "../docker/Dockerfile");

describe("guest bun version parity", () => {
  const src = readFileSync(DOCKERFILE, "utf8");

  it("declares BUN_VERSION exactly once", () => {
    const matches = src.match(/^ENV BUN_VERSION=/gm) ?? [];
    expect(matches.length).toBe(1);
  });

  it("downloads the guest bun from the musl-baseline asset pinned to BUN_VERSION", () => {
    // The guest-bun layer must reference ${BUN_VERSION} and the baseline asset.
    expect(src).toContain("bun-linux-x64-musl-baseline");
    expect(src).toMatch(/bun-v\$\{BUN_VERSION\}\/bun-linux-x64-musl-baseline/);
  });

  it("installs the guest bun at /opt/bun-guest/bun and records its version", () => {
    expect(src).toContain("/opt/bun-guest/bun");
    expect(src).toContain("/opt/bun-guest/VERSION");
  });
});
