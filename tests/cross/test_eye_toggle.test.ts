import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { describe, expect, it } from "vitest";

// tests/cross/test_eye_toggle.sh
// Static guards for the E1 eye-toggle replacement of D3 reveal tokens.

const REPO = resolve(import.meta.dirname, "../..");
const SB_VIEW = join(
  REPO,
  "luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui",
);
const DF = join(SB_VIEW, "lib/descriptor_form.js");

describe("test_eye_toggle", () => {
  describe("descriptor_form.js eye-toggle machinery (E1)", () => {
    const src = readFileSync(DF, "utf8");

    it("decorateSecretInput is defined in descriptor_form.js", () => {
      expect(src).toContain("function decorateSecretInput");
    });

    it("decorateSecretInput(opt) is invoked from applyMaterialized", () => {
      expect(src).toContain("decorateSecretInput(opt)");
    });
  });

  // The two "reveal-token machinery must be gone" greps that used to live here
  // are deleted: revealGrant / withRevealToken / reveal.uc / scrub.uc have ZERO
  // occurrences in the repo and the files do not exist. A grep for a string that
  // was never going to come back is not a guard, it is a permanent green tick.
});
