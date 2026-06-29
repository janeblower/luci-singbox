import { execSync } from "node:child_process";
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
const SB_LIB_VIEW = join(SB_VIEW, "lib");
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

  describe("reveal-token machinery must be gone from view tree", () => {
    it("no revealGrant / revealRevoke / withRevealToken / singboxUiRevealToken / reveal_token references", () => {
      const result = execSync(
        `grep -rn -E 'revealGrant|revealRevoke|withRevealToken|singboxUiRevealToken|reveal_token' "${SB_VIEW}" || true`,
        { encoding: "utf8" },
      );
      expect(result.trim()).toBe("");
    });
  });

  describe("reveal.uc / scrub.uc must not be required anywhere in lib tree", () => {
    it("no require reveal.uc or scrub.uc in view lib tree", () => {
      // The lib tree here is the JS view lib — check for any remnant JS require of those UC modules
      const result = execSync(
        `grep -rn -E "require.*reveal|require.*scrub" "${SB_LIB_VIEW}" || true`,
        { encoding: "utf8" },
      );
      expect(result.trim()).toBe("");
    });
  });
});
