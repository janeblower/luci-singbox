import { describe, it, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { execSync } from "node:child_process";

// Port of tests/backend/test_vm_no_node_tests.sh
//
// This test runs HOST-SIDE (no guest needed) — it checks the structure of
// run.sh and entrypoint.sh to ensure node/ui tests are excluded from the VM
// run path and that guard A (ucode hard-fail) text is intact.

const REPO = process.env.SB_VM_WORK
  ? `${process.env.SB_VM_WORK}` // in-VM: /tmp/work
  : `${process.cwd()}`; // on host: repo root

describe("test_vm_no_node_tests", () => {
  it("entrypoint sets SB_DOMAIN that includes backend but excludes ui", () => {
    const ep = readFileSync(`${REPO}/tests/docker/entrypoint.sh`, "utf8");

    // Must set SB_DOMAIN that includes backend
    expect(ep).toMatch(/SB_DOMAIN=["']?[^"']*backend/);

    // Must NOT include the ui domain (node tests must not run in VM)
    const uiMatch = /SB_DOMAIN=["'][^"']*\bui\b/.test(ep);
    expect(uiMatch).toBe(false);
  });

  it("dry-run VM list selects only backend tests (no ui/, no cross/)", () => {
    let out: string;
    try {
      out = execSync(
        "SB_DRY_RUN=1 SINGBOX_TESTS_IN_VM=1 SB_DOMAIN=backend SB_SUITE='backend ui cross' sh tests/run.sh",
        { cwd: REPO, encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] },
      );
    } catch (e: unknown) {
      // run.sh may exit non-zero in dry-run mode; capture stdout anyway
      out = (e as { stdout: string }).stdout ?? "";
    }

    expect(out).not.toMatch(/tests\/ui\//);
    expect(out).not.toMatch(/tests\/cross\//);
    expect(out).toMatch(/tests\/backend\//);
  });

  it("ucode hard-fail guard A text is present and unmodified in run.sh", () => {
    const runsh = readFileSync(`${REPO}/tests/run.sh`, "utf8");
    expect(runsh).toContain("SKIPped for a MISSING ucode interpreter");
  });
});
