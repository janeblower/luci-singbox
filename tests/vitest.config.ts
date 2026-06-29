import { defineConfig } from "vitest/config";

// Host unit + packaging lanes (Plan 4: bun:test -> vitest). Two projects, both
// node env — no test touches a real DOM (the few DOM-ish ui tests use plain
// node:vm stubs). tests/backend + tests/parity stay on bun-in-guest; tests/browser
// stays on @playwright/test. Paths are relative to this file's dir (tests/).
export default defineConfig({
  test: {
    // Run test files serially (bun:test ran them serially). Several packaging
    // tests under tests/cross mutate the working tree (stage files, regen
    // manifests) that file-scanning tests (e.g. test_install_lists_match) read,
    // so vitest's default parallel file execution races them. Match bun.
    fileParallelism: false,
    projects: [
      {
        test: {
          name: "ui",
          include: ["ui/**/*.test.ts"],
          environment: "node",
        },
      },
      {
        test: {
          name: "cross",
          include: ["cross/**/*.test.ts"],
          environment: "node",
        },
      },
    ],
  },
});
