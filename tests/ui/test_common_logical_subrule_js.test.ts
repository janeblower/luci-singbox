import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

// Unit tests for common.js logicalSubRuleValidate — the shared validator that
// the Route and DNS tabs both attach to a logical rule's sub-rule list. Code
// review #8: dns_rule logical sub-rules previously had NO validation (route_rule
// did), so pointing a DNS logical rule at itself or another logical rule
// silently dropped the whole rule with no feedback. The validator is now shared
// so the two tabs cannot drift again.

const COMMON_JS = resolve(
  import.meta.dir,
  "../../luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/lib/common.js",
);

function loadCommon() {
  const src = readFileSync(COMMON_JS, "utf8");
  const body = src
    .replace(/^'use strict';\s*/, "")
    .replace(/'require [^']*';\s*/g, "")
    .replace(/return L\.Class\.extend\(/, "return (");
  const form = {};
  const uci = {};
  const ui = {};
  const _g = (s: unknown) => s;
  const _E = () => ({});
  // biome-ignore lint/security/noGlobalEval: test harness mirrors the .sh approach
  const mod = new Function("_", "E", "form", "uci", "ui", body)(
    _g,
    _E,
    form,
    uci,
    ui,
  );
  return mod;
}

describe("common.js logicalSubRuleValidate", () => {
  const types: Record<string, string> = {
    def1: "default",
    def2: "default",
    log1: "logical",
  };
  const mockUci = { get: (_c: string, n: string, _o: string) => types[n] };
  const _ = (s: string) => s;
  const mod = loadCommon();
  const validate = mod.logicalSubRuleValidate(mockUci, _);

  it("exports logicalSubRuleValidate", () => {
    expect(typeof mod.logicalSubRuleValidate).toBe("function");
    expect(typeof validate).toBe("function");
  });

  it("rejects self-reference", () => {
    const r = validate("log1", ["log1"]);
    expect(typeof r).toBe("string");
    expect(r).toContain("itself");
  });

  it("rejects a non-default (logical) sub-rule", () => {
    const r = validate("me", ["log1"]);
    expect(typeof r).toBe("string");
    expect(r).toContain("log1");
  });

  it("accepts default sub-rules", () => {
    expect(validate("me", ["def1", "def2"])).toBe(true);
  });

  it("accepts empty / null / scalar values (nothing to validate)", () => {
    expect(validate("me", "")).toBe(true);
    expect(validate("me", null)).toBe(true);
    expect(validate("me", undefined)).toBe(true);
    expect(validate("me", "def1")).toBe(true);
  });

  it("treats an unknown sub-rule as default (uci.get undefined → 'default')", () => {
    expect(validate("me", ["ghost"])).toBe(true);
  });
});
