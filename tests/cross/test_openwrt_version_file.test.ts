import { describe, expect, it } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";

// tests/cross/test_openwrt_version_file.sh
// The single OpenWrt version source must exist and the Dockerfile must consume
// it via a build ARG (not a hardcoded literal in IMAGE_URL/IMAGE_FILE).

const REPO = resolve(import.meta.dir, "../..");
const VF = join(REPO, "tests/docker/openwrt-version.txt");
const DF = join(REPO, "tests/docker/Dockerfile");

describe("OpenWrt version file (single source of truth)", () => {
  it("tests/docker/openwrt-version.txt exists", () => {
    expect(existsSync(VF)).toBe(true);
  });

  it("version file contains an X.Y.Z string", () => {
    const ver = readFileSync(VF, "utf8").trim();
    expect(ver).toMatch(/^[0-9]+\.[0-9]+\.[0-9]+$/);
  });

  it("Dockerfile declares ARG OPENWRT_VERSION", () => {
    const df = readFileSync(DF, "utf8");
    expect(df).toMatch(/^ARG OPENWRT_VERSION/m);
  });

  it("Dockerfile IMAGE_URL/IMAGE_FILE reference the ARG, not a bare version literal", () => {
    const df = readFileSync(DF, "utf8");
    const ver = readFileSync(VF, "utf8").trim();
    // IMAGE_URL / IMAGE_FILE ENV lines must NOT have the raw version string —
    // they must use ${OPENWRT_VERSION} or $OPENWRT_VERSION interpolation.
    const lines = df
      .split("\n")
      .filter((l) => /^ENV (IMAGE_URL|IMAGE_FILE)/.test(l));
    for (const line of lines) {
      expect(line).not.toContain(ver);
    }
  });
});
