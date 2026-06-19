/**
 * tests/cross/test_uci_defaults_fwmark.test.ts
 * Port of tests/cross/test_uci_defaults_fwmark.sh
 *
 * Verifies the 90-singbox-ui-fwmark uci-defaults script:
 *   1. First run seeds three default values.
 *   2. Second run is idempotent (values unchanged).
 *   3. Does not overwrite user-set values.
 *
 * Requires `uci` — SKIPs on hosts without it (runs for real inside the
 * OpenWrt qemu VM).
 */
import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const REPO = resolve(import.meta.dir, "../..");
const SB_BACKEND_ROOT = join(REPO, "singbox-ui/root");
const FWMARK_SCRIPT = join(
  SB_BACKEND_ROOT,
  "etc/uci-defaults/90-singbox-ui-fwmark",
);

// Check if `uci` is available on this host.
const uciAvailable =
  spawnSync("sh", ["-c", "command -v uci"], { encoding: "utf8" }).status === 0;

// Helper: run `uci -c <dir> <args...>` and return trimmed stdout.
function uciGet(configDir: string, key: string): string {
  const r = spawnSync("uci", ["-c", configDir, "get", key], {
    encoding: "utf8",
  });
  return (r.stdout ?? "").trim();
}

function uciSet(configDir: string, key: string, value: string): void {
  const r = spawnSync("uci", ["-c", configDir, "set", `${key}=${value}`], {
    encoding: "utf8",
  });
  if (r.status !== 0) throw new Error(`uci set failed: ${r.stderr}`);
}

function uciCommit(configDir: string, pkg: string): void {
  const r = spawnSync("uci", ["-c", configDir, "commit", pkg], {
    encoding: "utf8",
  });
  if (r.status !== 0) throw new Error(`uci commit failed: ${r.stderr}`);
}

let UCI_DIR: string;

describe("test_uci_defaults_fwmark", () => {
  beforeAll(() => {
    if (!uciAvailable) return;
    UCI_DIR = mkdtempSync(join(tmpdir(), "fwmark-uci-"));
    mkdirSync(UCI_DIR, { recursive: true });
    // Create empty singbox-ui config file.
    writeFileSync(join(UCI_DIR, "singbox-ui"), "", "utf8");
  });

  afterAll(() => {
    if (!uciAvailable) return;
    if (UCI_DIR) rmSync(UCI_DIR, { recursive: true, force: true });
  });

  it.skipIf(!uciAvailable)("fwmark script exists and is executable", () => {
    const r = spawnSync("sh", ["-c", `[ -x "${FWMARK_SCRIPT}" ]`], {
      encoding: "utf8",
    });
    expect(r.status, `${FWMARK_SCRIPT} missing or not executable`).toBe(0);
  });

  it.skipIf(!uciAvailable)("first run seeds three defaults", () => {
    const r = spawnSync("sh", [FWMARK_SCRIPT], {
      encoding: "utf8",
      env: { ...process.env, UCI_CONFIG_DIR: UCI_DIR },
    });
    expect(r.status, `script failed:\n${r.stderr}`).toBe(0);

    expect(
      uciGet(UCI_DIR, "singbox-ui.@global[0].fwmark"),
      "fwmark wrong",
    ).toBe("0x40000000");
    expect(
      uciGet(UCI_DIR, "singbox-ui.@global[0].fwmark_mask"),
      "fwmark_mask wrong",
    ).toBe("0x40000000");
    expect(
      uciGet(UCI_DIR, "singbox-ui.@global[0].redirect_router_traffic"),
      "redirect_router_traffic wrong",
    ).toBe("0");
  });

  it.skipIf(!uciAvailable)("second run is idempotent (no value change)", () => {
    const r = spawnSync("sh", [FWMARK_SCRIPT], {
      encoding: "utf8",
      env: { ...process.env, UCI_CONFIG_DIR: UCI_DIR },
    });
    expect(r.status, `script failed on second run:\n${r.stderr}`).toBe(0);
    expect(
      uciGet(UCI_DIR, "singbox-ui.@global[0].fwmark"),
      "fwmark changed on second run",
    ).toBe("0x40000000");
  });

  it.skipIf(!uciAvailable)("does not overwrite user-set values", () => {
    uciSet(UCI_DIR, "singbox-ui.@global[0].fwmark", "0x100");
    uciCommit(UCI_DIR, "singbox-ui");

    const r = spawnSync("sh", [FWMARK_SCRIPT], {
      encoding: "utf8",
      env: { ...process.env, UCI_CONFIG_DIR: UCI_DIR },
    });
    expect(r.status, `script failed:\n${r.stderr}`).toBe(0);
    expect(
      uciGet(UCI_DIR, "singbox-ui.@global[0].fwmark"),
      "overwritten user value",
    ).toBe("0x100");
  });
});
