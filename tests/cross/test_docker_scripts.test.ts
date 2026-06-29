import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { describe, expect, it } from "vitest";

// tests/cross/test_docker_scripts.sh
// Lint the QEMU image scripts for two ordering/robustness invariants:
//   S5-6: entrypoint.sh must wait for SSH before tar|ssh injection.
//   S5-7: build-snapshot.sh must poll `info snapshots` (no blind sleep
//         deciding success) around savevm.

const REPO = resolve(import.meta.dirname, "../..");
const ENTRY = join(REPO, "tests/docker/entrypoint.sh");
const SNAP = join(REPO, "tests/docker/build-snapshot.sh");

describe("docker scripts structural invariants", () => {
  // ---------------------------------------------------------------------------
  // S5-6: entrypoint.sh must wait for SSH before tar|ssh injection
  // ---------------------------------------------------------------------------
  describe("S5-6: entrypoint.sh waits for SSH before tar|ssh push", () => {
    it("entrypoint.sh exists", () => {
      expect(existsSync(ENTRY)).toBe(true);
    });

    it("entrypoint.sh has a wait-ssh.sh call", () => {
      const src = readFileSync(ENTRY, "utf8");
      expect(src).toContain("wait-ssh.sh");
    });

    it("entrypoint.sh has a 'tar -czf -' push line", () => {
      const src = readFileSync(ENTRY, "utf8");
      expect(src).toContain("tar -czf -");
    });

    it("wait-ssh.sh call precedes tar|ssh push (line order)", () => {
      const lines = readFileSync(ENTRY, "utf8").split("\n");
      const waitLn = lines.findIndex((l) => l.includes("wait-ssh.sh"));
      const pushLn = lines.findIndex((l) => l.includes("tar -czf -"));
      // Both must be found (asserted above); here assert ordering
      expect(waitLn).toBeGreaterThanOrEqual(0);
      expect(pushLn).toBeGreaterThanOrEqual(0);
      expect(waitLn).toBeLessThan(pushLn);
    });
  });

  // ---------------------------------------------------------------------------
  // S5-7: build-snapshot.sh must poll 'info snapshots' (not blind sleep)
  // ---------------------------------------------------------------------------
  describe("S5-7: build-snapshot.sh polls 'info snapshots' around savevm", () => {
    it("build-snapshot.sh exists", () => {
      expect(existsSync(SNAP)).toBe(true);
    });

    it("contains 'savevm boot-state'", () => {
      const src = readFileSync(SNAP, "utf8");
      expect(src).toContain("savevm boot-state");
    });

    it("contains 'info snapshots' poll", () => {
      const src = readFileSync(SNAP, "utf8");
      expect(src).toContain("info snapshots");
    });

    it("contains a poll loop (while|for|until)", () => {
      const src = readFileSync(SNAP, "utf8");
      expect(src).toMatch(/while|for|until/);
    });

    it("has a savevm readiness poll (not just blind sleep)", () => {
      // A loop body that probes `info snapshots` for boot-state must exist.
      // The old blind-sleep form had `info snapshots` only as a one-shot
      // diagnostic between fixed sleeps, never as a readiness gate.
      const src = readFileSync(SNAP, "utf8");
      const hasInlineProbe =
        /info snapshots.*boot-state|boot-state.*info snapshots/.test(src);
      const hasNamedGate = /snap_ready|while .*savevm|savevm_done/.test(src);
      expect(hasInlineProbe || hasNamedGate).toBe(true);
    });
  });
});
