import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";

// tests/cross/test_grid_columns.sh
// Static guard: every taboption('basic', ...) in tabs/outbounds.js and
// tabs/inbounds.js must either be one of the whitelisted column names or
// have modalonly=true on one of the next 5 lines.

const REPO = resolve(import.meta.dir, "../..");
const SB_VIEW = join(
  REPO,
  "luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui",
);

const WHITELIST = new Set([
  "enabled",
  "_export",
  "_address",
  "type",
  "protocol",
  "__rename",
]);

function checkFile(filePath: string): string[] {
  const src = readFileSync(filePath, "utf8");
  const lines = src.split("\n");
  const failures: string[] = [];
  const parts = filePath.split("/");
  const filename = parts[parts.length - 1] ?? filePath;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    // Match lines with s.taboption('basic', ...)
    if (!line.includes("s.taboption('basic'")) {
      continue;
    }

    // Extract 3rd comma-separated arg (field name), strip quotes and whitespace.
    // Pattern: s.taboption('basic', <widget>, '<name>'...)
    const m = line.match(/s\.taboption\([^,]+,[^,]+,\s*['"]([^'"]+)['"]/);
    if (!m) {
      continue;
    }
    const name = m[1];

    if (WHITELIST.has(name)) {
      continue;
    }

    // Check next 5 lines for modalonly = true
    const nextLines = lines.slice(i + 1, i + 6).join("\n");
    if (/modalonly\s*=\s*true/.test(nextLines)) {
      continue;
    }

    failures.push(
      `${filename}:${i + 1} field '${name}' is neither whitelisted nor modalonly=true`,
    );
  }

  return failures;
}

describe("test_grid_columns", () => {
  it("tabs/outbounds.js: all taboption('basic') fields are whitelisted or modalonly", () => {
    const failures = checkFile(join(SB_VIEW, "tabs/outbounds.js"));
    expect(failures).toEqual([]);
  });

  it("tabs/inbounds.js: all taboption('basic') fields are whitelisted or modalonly", () => {
    const failures = checkFile(join(SB_VIEW, "tabs/inbounds.js"));
    expect(failures).toEqual([]);
  });
});
