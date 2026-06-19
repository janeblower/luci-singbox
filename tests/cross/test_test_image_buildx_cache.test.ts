import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";

// tests/cross/test_test_image_buildx_cache.sh
// Guard: test-image.yml must use a buildx layer cache so re-runs are fast.

const REPO = resolve(import.meta.dir, "../..");
const TI = join(REPO, ".github/workflows/test-image.yml");

describe("test-image.yml buildx cache config", () => {
  it("has an actions/cache@ step", () => {
    const yml = readFileSync(TI, "utf8");
    expect(yml).toContain("actions/cache@");
  });

  it("caches the buildx layer directory (/tmp/.buildx-cache)", () => {
    const yml = readFileSync(TI, "utf8");
    expect(yml).toContain("/tmp/.buildx-cache");
  });

  it("build-push-action has cache-from: type=local", () => {
    const yml = readFileSync(TI, "utf8");
    expect(yml).toContain("cache-from: type=local");
  });

  it("build-push-action has cache-to: type=local", () => {
    const yml = readFileSync(TI, "utf8");
    expect(yml).toContain("cache-to: type=local");
  });
});
