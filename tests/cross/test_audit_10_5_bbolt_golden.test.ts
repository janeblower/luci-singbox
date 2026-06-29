/**
 * tests/cross/test_audit_10_5_bbolt_golden.test.ts
 * Port of tests/cross/test_audit_10_5_bbolt_golden.sh
 *
 * Wires the bbolt-client golden suite (bbolt-client/test.sh) into the main
 * test run (audit 10.5).  SKIPs unless the native bbolt-client-rs binary has
 * been built locally (i.e. `bbolt-client/bbolt-client-rs` exists and is
 * executable).  This matches the original shell test's behaviour exactly.
 *
 * The bbolt-client.yml CI workflow still runs the full cross-arch matrix;
 * this is the integration-pass smoke that catches real-vs-stub drift when a
 * developer happens to have a local build.
 *
 * Env override: BBOLT_TEST_BIN — path to the binary (mirrors the shell test's
 * RUN= / BBOLT_TEST_BIN= convention).
 */

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { join, resolve } from "node:path";
import { describe, expect, it } from "vitest";

const REPO = resolve(import.meta.dirname, "../..");
const BBOLT_DIR = join(REPO, "bbolt-client");
const DEFAULT_BIN = join(BBOLT_DIR, "bbolt-client-rs");
const GOLDEN_TESTDATA = join(BBOLT_DIR, "testdata", "cache.db");
const BBOLT_TEST_SH = join(BBOLT_DIR, "test.sh");

// Use the env override if provided, otherwise default to the native build.
const BIN = process.env.BBOLT_TEST_BIN ?? DEFAULT_BIN;

// Skip conditions (mirrors the shell test's guards).
const bboltDirPresent = existsSync(BBOLT_DIR);
const binBuilt =
  existsSync(BIN) &&
  (() => {
    // Check executable bit.
    try {
      return (
        spawnSync("sh", ["-c", `[ -x "${BIN}" ]`], { encoding: "utf8" })
          .status === 0
      );
    } catch {
      return false;
    }
  })();
const goldenPresent = existsSync(GOLDEN_TESTDATA);

const canRun = bboltDirPresent && binBuilt && goldenPresent;

describe("test_audit_10_5_bbolt_golden", () => {
  it.skipIf(!bboltDirPresent)("bbolt-client directory present", () => {
    expect(existsSync(BBOLT_DIR)).toBe(true);
  });

  it.skipIf(!bboltDirPresent || !goldenPresent)(
    "golden testdata present",
    () => {
      expect(existsSync(GOLDEN_TESTDATA)).toBe(true);
    },
  );

  it.skipIf(!canRun)(
    "bbolt-client golden suite passes (real binary, end-to-end)",
    () => {
      // Check whether `od` is available (needed for the full golden suite).
      const odAvailable =
        spawnSync("sh", ["-c", "command -v od"], { encoding: "utf8" })
          .status === 0;

      const r = spawnSync("sh", [BBOLT_TEST_SH], {
        encoding: "utf8",
        env: { ...process.env, RUN: BIN },
        cwd: REPO,
        timeout: 120_000,
      });

      if (!odAvailable) {
        // Minimal path: od not available (OpenWrt/busybox guest).
        // We still expect clean exit — basic invocation smoke.
        expect(
          r.status,
          `bbolt-client minimal smoke failed:\n${r.stdout}\n${r.stderr}`,
        ).toBe(0);
        return;
      }

      // Full golden suite: sha256 comparison + adversarial/forged tests.
      expect(
        r.status,
        `bbolt-client golden suite failed:\n${r.stdout}\n${r.stderr}`,
      ).toBe(0);
    },
  );
});
