import { describe, expect, it } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";

// tests/cross/test_route_tab_structure_js.sh
// Guards Bug 2: route.js must declare a tab and add base fields via taboption,
// matching the working inbounds/outbounds pattern (untabbed s.option breaks the
// GridSection modal once applyMaterialized injects match/action tabs).

const REPO = resolve(import.meta.dir, "../..");
const SB_VIEW = join(
  REPO,
  "luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui",
);
const F = join(SB_VIEW, "tabs/route.js");

describe("test_route_tab_structure_js", () => {
  it("tabs/route.js exists", () => {
    expect(existsSync(F)).toBe(true);
  });

  describe("route_rule section tab declarations", () => {
    const src = readFileSync(F, "utf8");

    // Route-rule section must pre-declare the match tab.
    it("declares the 'match' tab (s.tab('match'...))", () => {
      expect(src).toContain("s.tab('match'");
    });

    // Base fields (enabled/type) must be taboption, not bare option.
    it("enabled added via taboption('match', form.Flag, 'enabled'...)", () => {
      expect(src).toContain("s.taboption('match', form.Flag, 'enabled'");
    });

    it("type added via taboption('match', form.ListValue, 'type'...)", () => {
      expect(src).toContain("s.taboption('match', form.ListValue, 'type'");
    });
  });

  describe("rule_set section tab declarations", () => {
    const src = readFileSync(F, "utf8");

    // Rule-Sets section must declare its tab and use taboption too.
    it("declares the 'basic' tab (s.tab('basic'...))", () => {
      expect(src).toContain("s.tab('basic'");
    });

    it("rule_set enabled added via taboption('basic', form.Flag, 'enabled'...)", () => {
      expect(src).toContain("s.taboption('basic', form.Flag, 'enabled'");
    });

    it("rule_set type added via taboption('basic', form.ListValue, 'type'...)", () => {
      expect(src).toContain("s.taboption('basic', form.ListValue, 'type'");
    });
  });

  describe("regression lock: base fields must NOT be untabbed s.option()", () => {
    const src = readFileSync(F, "utf8");

    it("base 'enabled' not reverted to untabbed s.option(form.Flag, 'enabled'...)", () => {
      expect(src).not.toContain("s.option(form.Flag, 'enabled'");
    });

    it("base 'type' not reverted to untabbed s.option(form.ListValue, 'type'...)", () => {
      expect(src).not.toContain("s.option(form.ListValue, 'type'");
    });
  });
});
