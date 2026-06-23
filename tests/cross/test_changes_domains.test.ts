import { describe, expect, it } from "bun:test";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";

// tests/cross/test_changes_domains.sh
// Exercises the pure path->domain classifier (tests/lib/domain_classify.sh)
// used by tests/run.sh's SB_DOMAIN filter. Also guards the static wiring of
// the CI `changes` job (dorny/paths-filter in build.yml).
//
// Directory-based 4-domain model:
//   bbolt / backend / ui / packaging, plus a shared fan-out that sets all four.
//
// NOTE: The classifier (domain_classify.sh) is a shell script sourced into sh.
// We invoke it via sh subprocess to replicate the exact logic faithfully.

const REPO = resolve(import.meta.dir, "../..");
const CLASSIFY = join(REPO, "tests/lib/domain_classify.sh");
const BUILD_YML = join(REPO, ".github/workflows/build.yml");

/** Run domain_classify.sh on a newline-separated file list; return parsed map. */
function classify(files: string): Record<string, string> {
  const result = spawnSync(
    "sh",
    [
      "-c",
      `
. "${CLASSIFY}"
printf '%s\\n' "${files.replace(/"/g, '\\"')}" | sb_classify_domains
`,
    ],
    { encoding: "utf8" },
  );
  if (result.status !== 0) {
    throw new Error(`classify failed: ${result.stderr}`);
  }
  const out: Record<string, string> = {};
  for (const line of result.stdout.split("\n")) {
    const m = line.match(/^(\w+)=(true|false)$/);
    if (m) out[m[1]] = m[2];
  }
  return out;
}

/** Assert one domain variable has the expected value. */
function expectDomain(files: string, varName: string, want: "true" | "false") {
  const got = classify(files);
  expect(got[varName]).toBe(want);
}

describe("domain classifier: path -> domain mapping", () => {
  // 1) bbolt-only change => ONLY bbolt true (the goal-e isolation invariant).
  describe("1) bbolt-only change", () => {
    const f = "bbolt-client/src/main.rs";
    it("bbolt=true", () => expectDomain(f, "bbolt", "true"));
    it("backend=false", () => expectDomain(f, "backend", "false"));
    it("ui=false", () => expectDomain(f, "ui", "false"));
    it("packaging=false", () => expectDomain(f, "packaging", "false"));
  });

  // 2) backend ucode change => only backend.
  describe("2) backend ucode change", () => {
    const f = "singbox-ui/root/usr/share/singbox-ui/lib/outbound.uc";
    it("backend=true", () => expectDomain(f, "backend", "true"));
    it("bbolt=false", () => expectDomain(f, "bbolt", "false"));
    it("ui=false", () => expectDomain(f, "ui", "false"));
    it("packaging=false", () => expectDomain(f, "packaging", "false"));
  });

  // 3) parity fixture => backend (parity belongs to the backend builder).
  describe("3) parity fixture", () => {
    const f = "tests/parity/corpus.uc";
    it("backend=true", () => expectDomain(f, "backend", "true"));
    it("ui=false", () => expectDomain(f, "ui", "false"));
  });

  // 4) tests/backend/* => backend.
  describe("4) tests/backend/*", () => {
    const f = "tests/backend/test_outbound_uc.sh";
    it("backend=true", () => expectDomain(f, "backend", "true"));
    it("bbolt=false", () => expectDomain(f, "bbolt", "false"));
  });

  // 5) UI source => only ui.
  describe("5) UI source", () => {
    const f =
      "luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/main.js";
    it("ui=true", () => expectDomain(f, "ui", "true"));
    it("backend=false", () => expectDomain(f, "backend", "false"));
    it("packaging=false", () => expectDomain(f, "packaging", "false"));
  });

  // 6) tests/ui and tests/browser => ui.
  describe("6) tests/ui and tests/browser", () => {
    it("tests/ui/* => ui=true", () =>
      expectDomain("tests/ui/test_validators_js.sh", "ui", "true"));
    it("tests/browser/* => ui=true", () =>
      expectDomain("tests/browser/01-outbounds.mjs", "ui", "true"));
  });

  // 7) packaging: scripts, install.sh, feed, any Makefile, tests/cross.
  describe("7) packaging paths", () => {
    it("scripts/build-apk.sh => packaging=true", () =>
      expectDomain("scripts/build-apk.sh", "packaging", "true"));
    it("install.sh => packaging=true", () =>
      expectDomain("install.sh", "packaging", "true"));
    it("feed/luci-singbox.pem => packaging=true", () =>
      expectDomain("feed/luci-singbox.pem", "packaging", "true"));
    it("singbox-ui/Makefile => packaging=true", () =>
      expectDomain("singbox-ui/Makefile", "packaging", "true"));
    it("luci-app-singbox-ui/Makefile => packaging=true", () =>
      expectDomain("luci-app-singbox-ui/Makefile", "packaging", "true"));
    it("Makefile (root) => packaging=true", () =>
      expectDomain("Makefile", "packaging", "true"));
    it("tests/cross/test_build_feed.sh => packaging=true", () =>
      expectDomain("tests/cross/test_build_feed.sh", "packaging", "true"));
    it("scripts/build-apk.sh => backend=false", () =>
      expectDomain("scripts/build-apk.sh", "backend", "false"));
  });

  // 8) shared fan-out: tests/lib, tests/run*, tests/docker,
  //    tests/browser-container, .github => ALL FOUR true.
  describe("8) shared fan-out (all four domains)", () => {
    const sharedFiles = [
      "tests/lib/sb_helpers.sh",
      "tests/run-vm.sh",
      "tests/docker/Dockerfile",
      "tests/browser-container/Dockerfile",
      ".github/workflows/build.yml",
    ];
    for (const f of sharedFiles) {
      for (const d of ["bbolt", "backend", "ui", "packaging"] as const) {
        it(`${f} => ${d}=true`, () => expectDomain(f, d, "true"));
      }
    }
  });

  // 8b) the standalone sing-box-extended workflow is EXCLUDED from the .github
  //     shared fan-out: changing ONLY it must trigger no domain.
  describe("8b) sing-box-extended.yml carve-out", () => {
    const sbx = ".github/workflows/sing-box-extended.yml";
    it("sbx alone: bbolt=false", () => expectDomain(sbx, "bbolt", "false"));
    it("sbx alone: backend=false", () => expectDomain(sbx, "backend", "false"));
    it("sbx alone: ui=false", () => expectDomain(sbx, "ui", "false"));
    it("sbx alone: packaging=false", () =>
      expectDomain(sbx, "packaging", "false"));

    // A real shared github change alongside it still fans out
    const sbxPlus =
      ".github/workflows/sing-box-extended.yml\n.github/workflows/build.yml";
    it("sbx + build.yml: bbolt=true", () =>
      expectDomain(sbxPlus, "bbolt", "true"));
    it("sbx + build.yml: backend=true", () =>
      expectDomain(sbxPlus, "backend", "true"));
    it("sbx + build.yml: ui=true", () => expectDomain(sbxPlus, "ui", "true"));
    it("sbx + build.yml: packaging=true", () =>
      expectDomain(sbxPlus, "packaging", "true"));

    // Realistic combo: sbx workflow + a packaging file => packaging ONLY, not full fan-out
    const sbxPkg =
      ".github/workflows/sing-box-extended.yml\nscripts/build-feed.sh";
    it("sbx + packaging file: packaging=true", () =>
      expectDomain(sbxPkg, "packaging", "true"));
    it("sbx + packaging file: bbolt=false", () =>
      expectDomain(sbxPkg, "bbolt", "false"));
    it("sbx + packaging file: backend=false", () =>
      expectDomain(sbxPkg, "backend", "false"));
    it("sbx + packaging file: ui=false", () =>
      expectDomain(sbxPkg, "ui", "false"));
  });

  // 9) multi-file change unions domains: bbolt + ui => both true, backend/packaging false.
  describe("9) multi-file change unions domains", () => {
    const multi =
      "bbolt-client/build.sh\nluci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/tabs/dns.js";
    it("bbolt=true", () => expectDomain(multi, "bbolt", "true"));
    it("ui=true", () => expectDomain(multi, "ui", "true"));
    it("backend=false", () => expectDomain(multi, "backend", "false"));
    it("packaging=false", () => expectDomain(multi, "packaging", "false"));
  });

  // 10) empty input => everything false (no changed files).
  describe("10) empty input => all domains false", () => {
    for (const d of ["bbolt", "backend", "ui", "packaging"] as const) {
      it(`${d}=false`, () => expectDomain("", d, "false"));
    }
  });

  // Goal-e isolation matrix
  describe("goal-e isolation matrix", () => {
    it("bbolt-client/src/main.rs: bbolt=T backend=F ui=F packaging=F", () => {
      const f = "bbolt-client/src/main.rs";
      const r = classify(f);
      expect(r).toMatchObject({
        bbolt: "true",
        backend: "false",
        ui: "false",
        packaging: "false",
      });
    });
    it("singbox-ui/.../outbound.uc: bbolt=F backend=T ui=F packaging=F", () => {
      const f = "singbox-ui/root/usr/share/singbox-ui/lib/outbound.uc";
      const r = classify(f);
      expect(r).toMatchObject({
        bbolt: "false",
        backend: "true",
        ui: "false",
        packaging: "false",
      });
    });
    it("luci-app-singbox-ui/.../main.js: bbolt=F backend=F ui=T packaging=F", () => {
      const f =
        "luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/main.js";
      const r = classify(f);
      expect(r).toMatchObject({
        bbolt: "false",
        backend: "false",
        ui: "true",
        packaging: "false",
      });
    });
    it("scripts/build-apk.sh: bbolt=F backend=F ui=F packaging=T", () => {
      const f = "scripts/build-apk.sh";
      const r = classify(f);
      expect(r).toMatchObject({
        bbolt: "false",
        backend: "false",
        ui: "false",
        packaging: "true",
      });
    });
    it("tests/lib/sb_helpers.sh (shared): all=true", () => {
      const f = "tests/lib/sb_helpers.sh";
      const r = classify(f);
      expect(r).toMatchObject({
        bbolt: "true",
        backend: "true",
        ui: "true",
        packaging: "true",
      });
    });
  });
});

// ---------------------------------------------------------------------------
// Static wiring guard: build.yml `changes` job uses dorny/paths-filter
// ---------------------------------------------------------------------------
describe("static wiring guard: build.yml changes job (dorny/paths-filter)", () => {
  it("changes job uses dorny/paths-filter", () => {
    const yml = readFileSync(BUILD_YML, "utf8");
    expect(yml).toMatch(/dorny\/paths-filter@/);
  });

  for (const domain of ["bbolt", "backend", "ui", "packaging"]) {
    it(`changes job exports ${domain} as steps.agg.outputs.${domain}`, () => {
      const yml = readFileSync(BUILD_YML, "utf8");
      expect(yml).toMatch(new RegExp(`steps\\.agg\\.outputs\\.${domain}`));
    });
  }

  it("bbolt job is gated on needs.changes.outputs.bbolt == 'true'", () => {
    const yml = readFileSync(BUILD_YML, "utf8");
    expect(yml).toMatch(/needs\.changes\.outputs\.bbolt == 'true'/);
  });

  it("test job is gated on needs.changes.outputs.backend == 'true'", () => {
    const yml = readFileSync(BUILD_YML, "utf8");
    expect(yml).toMatch(/needs\.changes\.outputs\.backend == 'true'/);
  });

  it("ui jobs are gated on needs.changes.outputs.ui == 'true'", () => {
    const yml = readFileSync(BUILD_YML, "utf8");
    expect(yml).toMatch(/needs\.changes\.outputs\.ui == 'true'/);
  });

  it("packaging job is gated on needs.changes.outputs.packaging == 'true'", () => {
    const yml = readFileSync(BUILD_YML, "utf8");
    expect(yml).toMatch(/needs\.changes\.outputs\.packaging == 'true'/);
  });

  it("changes job has the sing-box-extended carve-out", () => {
    const yml = readFileSync(BUILD_YML, "utf8");
    expect(yml).toMatch(/sing-box-extended\.yml/);
  });
});
