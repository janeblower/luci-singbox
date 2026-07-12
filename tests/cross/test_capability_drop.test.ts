import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { describe, expect, it } from "vitest";

// tests/cross/test_capability_drop.sh
// Checks the sing-box capability file shape and init.d wiring.

const REPO = resolve(import.meta.dirname, "../..");
const SB_BACKEND_ROOT = join(REPO, "singbox-ui/root");
const CAP_FILE = join(SB_BACKEND_ROOT, "etc/capabilities/singbox-ui.json");
const INITD = join(SB_BACKEND_ROOT, "etc/init.d/singbox-ui");

describe("test_capability_drop", () => {
  describe("capability file exists with correct shape", () => {
    it("capability file exists", () => {
      expect(existsSync(CAP_FILE)).toBe(true);
    });

    it("CAP_NET_ADMIN present in capability file", () => {
      const src = readFileSync(CAP_FILE, "utf8");
      expect(src).toContain("CAP_NET_ADMIN");
    });

    it("CAP_NET_RAW present in capability file", () => {
      const src = readFileSync(CAP_FILE, "utf8");
      expect(src).toContain("CAP_NET_RAW");
    });

    it("CAP_NET_BIND_SERVICE present in capability file", () => {
      const src = readFileSync(CAP_FILE, "utf8");
      expect(src).toContain("CAP_NET_BIND_SERVICE");
    });
  });

  it("init.d declares procd_set_param capabilities", () => {
    const src = readFileSync(INITD, "utf8");
    expect(src).toContain("procd_set_param capabilities");
  });
});
