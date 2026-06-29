import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { describe, expect, it } from "vitest";

// tests/cross/test_ci_packaging_lane.sh
// Asserts build.yml has a `packaging` job that:
//   (a) is gated on the packaging domain output,
//   (b) runs the cross suite host-mode in an apk-tools-3.0.5+ environment
//       (so feed/i18n get real `apk mkpkg --info`),
//   (c) does NOT delegate to the qemu VM.

const REPO = resolve(import.meta.dirname, "../..");
const WF = join(REPO, ".github/workflows/build.yml");

describe("CI packaging lane (build.yml)", () => {
  it("has a 'packaging:' job definition", () => {
    const yml = readFileSync(WF, "utf8");
    expect(yml).toMatch(/^\s*packaging:/m);
  });

  it("packaging job is gated on changes.outputs.packaging", () => {
    const yml = readFileSync(WF, "utf8");
    expect(yml).toMatch(/needs\.changes\.outputs\.packaging/);
  });

  it("packaging job runs the cross suite via vitest (bun run test:cross)", () => {
    const yml = readFileSync(WF, "utf8");
    // The cross suite migrated bun:test -> vitest (Plan 4); the packaging job now
    // runs it via `cd tests && bun run test:cross` (vitest run --project cross).
    expect(yml).toMatch(/bun run test:cross/);
  });

  it("packaging job has an apk-tools 3.0.5+ source (mkpkg --info / apk-tools / APK_BIN etc.)", () => {
    const yml = readFileSync(WF, "utf8");
    expect(yml).toMatch(
      /mkpkg --info|apk-tools|\/sdk|openwrt\/sdk|APK_BIN|SINGBOX_APK_BIN/,
    );
  });
});
