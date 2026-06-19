import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";

// tests/cross/test_ci_packaging_lane.sh
// Asserts build.yml has a `packaging` job that:
//   (a) is gated on the packaging domain output,
//   (b) runs the cross suite host-mode in an apk-tools-3.0.5+ environment
//       (so feed/i18n get real `apk mkpkg --info`),
//   (c) does NOT delegate to the qemu VM.

const REPO = resolve(import.meta.dir, "../..");
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

  it("packaging job runs the cross suite via bun (bun test tests/cross)", () => {
    const yml = readFileSync(WF, "utf8");
    // The legacy `SB_SUITE=cross sh tests/run.sh` shell lane was removed in the
    // bun migration; the packaging job now runs the cross suite via bun.
    expect(yml).toMatch(/bun test tests\/cross/);
  });

  it("packaging job has an apk-tools 3.0.5+ source (mkpkg --info / apk-tools / APK_BIN etc.)", () => {
    const yml = readFileSync(WF, "utf8");
    expect(yml).toMatch(
      /mkpkg --info|apk-tools|\/sdk|openwrt\/sdk|APK_BIN|SINGBOX_APK_BIN/,
    );
  });
});
