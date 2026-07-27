import { execFileSync } from "node:child_process";
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { describe, expect, it } from "vitest";

// main.js must parse. That is the whole test: `node --check` is the one thing
// biome does not already do for this file.

const REPO = resolve(import.meta.dirname, "../..");
const SB_UI_HTDOCS = join(REPO, "luci-app-singbox-ui/htdocs");
const SB_VIEW = join(SB_UI_HTDOCS, "luci-static/resources/view/singbox-ui");
const JS = join(SB_VIEW, "main.js");

const nodeAvailable = (() => {
  try {
    execFileSync("node", ["--version"], { stdio: "pipe" });
    return true;
  } catch {
    return false;
  }
})();

describe("test_main_js_syntax", () => {
  it("main.js exists", () => {
    expect(existsSync(JS)).toBe(true);
  });

  it.skipIf(!nodeAvailable)(
    "main.js passes node --check (wrapped in function)",
    () => {
      const src = readFileSync(JS, "utf8");
      const tmpDir = mkdtempSync(join(tmpdir(), "sb-syntax-"));
      const tmpFile = join(tmpDir, "main_check.js");
      writeFileSync(tmpFile, `(function () {\n${src}\n});`);
      try {
        execFileSync("node", ["--check", tmpFile], { stdio: "pipe" });
      } finally {
        unlinkSync(tmpFile);
      }
    },
  );

  // Everything that used to follow was `expect(source).toContain(<word>)`: 245
  // lines asserting that main.js literally contains the string "monitoring", the
  // string "'require form'", and so on. That is not a test of behaviour — it is a
  // copy of the file, kept in a second place, that goes red when the file is
  // reworded and stays green when the page breaks. `node --check` above is the
  // part biome does not already cover; the rest of main.js is covered by the
  // browser lane, which loads it in a real LuCI.
});
