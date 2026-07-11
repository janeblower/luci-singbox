import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { describe, expect, it } from "vitest";

// tests/cross/test_changes_domains.sh
// Exercises the pure path->domain classifier (tests/lib/domain_classify.sh),
// the hand-maintained mirror of the CI `changes` job's dorny/paths-filter
// globs (build.yml) whose static wiring this test guards.
//
// Directory-based 3-domain model:
//   backend / ui / packaging, plus a shared fan-out that sets all three.
//   bbolt-client/ (the former per-arch Rust reader, now a pure-ucode golden
//   harness for lib/bbolt.uc) maps to backend.
//
// NOTE: The classifier (domain_classify.sh) is a shell script sourced into sh.
// We invoke it via sh subprocess to replicate the exact logic faithfully.

const REPO = resolve(import.meta.dirname, "../..");
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
  // 1) bbolt-client harness change => backend (the ucode reader is backend code).
  describe("1) bbolt-client golden harness change", () => {
    const f = "bbolt-client/test.sh";
    it("backend=true", () => expectDomain(f, "backend", "true"));
    it("ui=false", () => expectDomain(f, "ui", "false"));
    it("packaging=false", () => expectDomain(f, "packaging", "false"));
  });

  // 2) backend ucode change => only backend.
  describe("2) backend ucode change", () => {
    const f = "singbox-ui/root/usr/share/singbox-ui/lib/outbound.uc";
    it("backend=true", () => expectDomain(f, "backend", "true"));
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
    it("ui=false", () => expectDomain(f, "ui", "false"));
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
  //    tests/browser-container, .github => ALL THREE true.
  describe("8) shared fan-out (all three domains)", () => {
    const sharedFiles = [
      "tests/lib/sb_helpers.sh",
      "tests/run-vm.sh",
      "tests/docker/Dockerfile",
      "tests/browser-container/Dockerfile",
      ".github/workflows/build.yml",
    ];
    for (const f of sharedFiles) {
      for (const d of ["backend", "ui", "packaging"] as const) {
        it(`${f} => ${d}=true`, () => expectDomain(f, d, "true"));
      }
    }
  });

  // 8b) the standalone sing-box-extended workflow is EXCLUDED from the .github
  //     shared fan-out: changing ONLY it must trigger no domain.
  describe("8b) sing-box-extended.yml carve-out", () => {
    const sbx = ".github/workflows/sing-box-extended.yml";
    it("sbx alone: backend=false", () => expectDomain(sbx, "backend", "false"));
    it("sbx alone: ui=false", () => expectDomain(sbx, "ui", "false"));
    it("sbx alone: packaging=false", () =>
      expectDomain(sbx, "packaging", "false"));

    // A real shared github change alongside it still fans out
    const sbxPlus =
      ".github/workflows/sing-box-extended.yml\n.github/workflows/build.yml";
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
    it("sbx + packaging file: backend=false", () =>
      expectDomain(sbxPkg, "backend", "false"));
    it("sbx + packaging file: ui=false", () =>
      expectDomain(sbxPkg, "ui", "false"));
  });

  // 9) multi-file change unions domains: backend + ui => both true, packaging false.
  describe("9) multi-file change unions domains", () => {
    const multi =
      "bbolt-client/test.sh\nluci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/tabs/dns.js";
    it("backend=true", () => expectDomain(multi, "backend", "true"));
    it("ui=true", () => expectDomain(multi, "ui", "true"));
    it("packaging=false", () => expectDomain(multi, "packaging", "false"));
  });

  // 10) empty input => everything false (no changed files).
  describe("10) empty input => all domains false", () => {
    for (const d of ["backend", "ui", "packaging"] as const) {
      it(`${d}=false`, () => expectDomain("", d, "false"));
    }
  });

  // 11) AWG-WARP plugin paths: root/ => backend, htdocs/ => ui, Makefile => packaging.
  describe("11) AWG-WARP plugin path-gating", () => {
    it("plugin root/ (ucode) => backend=true", () =>
      expectDomain(
        "plugins/awg_warp/lib/protocols/awg_warp.uc",
        "backend",
        "true",
      ));
    it("plugin root/ => ui=false", () =>
      expectDomain(
        "plugins/awg_warp/lib/protocols/awg_warp.uc",
        "ui",
        "false",
      ));
    it("plugin root/ => packaging=false", () =>
      expectDomain(
        "plugins/awg_warp/lib/protocols/awg_warp.uc",
        "packaging",
        "false",
      ));
    it("plugin htdocs/ (JS) => ui=true", () =>
      expectDomain(
        "plugins/awg_warp/htdocs/luci-static/resources/view/singbox-ui/plugins/awg_warp/tab.js",
        "ui",
        "true",
      ));
    it("plugin htdocs/ => backend=false", () =>
      expectDomain(
        "plugins/awg_warp/htdocs/luci-static/resources/view/singbox-ui/plugins/awg_warp/tab.js",
        "backend",
        "false",
      ));
    it("plugin Makefile => packaging=true", () =>
      expectDomain("plugins/awg_warp/Makefile", "packaging", "true"));
    it("plugin Makefile => backend=false", () =>
      expectDomain("plugins/awg_warp/Makefile", "backend", "false"));
    it("plugin Makefile => ui=false", () =>
      expectDomain("plugins/awg_warp/Makefile", "ui", "false"));
    it("plugin root/ (acl.d, provision script) => backend=true", () =>
      expectDomain(
        "plugins/awg_warp/root/usr/libexec/singbox-ui/awg-provision.sh",
        "backend",
        "true",
      ));
    it("plugin root/ => ui=false", () =>
      expectDomain(
        "plugins/awg_warp/root/usr/libexec/singbox-ui/awg-provision.sh",
        "ui",
        "false",
      ));
    it("plugin root/ => packaging=false", () =>
      expectDomain(
        "plugins/awg_warp/root/usr/libexec/singbox-ui/awg-provision.sh",
        "packaging",
        "false",
      ));
  });

  // isolation matrix
  describe("isolation matrix", () => {
    it("bbolt-client/test.sh: backend=T ui=F packaging=F", () => {
      const r = classify("bbolt-client/test.sh");
      expect(r).toMatchObject({
        backend: "true",
        ui: "false",
        packaging: "false",
      });
    });
    it("singbox-ui/.../outbound.uc: backend=T ui=F packaging=F", () => {
      const f = "singbox-ui/root/usr/share/singbox-ui/lib/outbound.uc";
      const r = classify(f);
      expect(r).toMatchObject({
        backend: "true",
        ui: "false",
        packaging: "false",
      });
    });
    it("luci-app-singbox-ui/.../main.js: backend=F ui=T packaging=F", () => {
      const f =
        "luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/main.js";
      const r = classify(f);
      expect(r).toMatchObject({
        backend: "false",
        ui: "true",
        packaging: "false",
      });
    });
    it("scripts/build-apk.sh: backend=F ui=F packaging=T", () => {
      const r = classify("scripts/build-apk.sh");
      expect(r).toMatchObject({
        backend: "false",
        ui: "false",
        packaging: "true",
      });
    });
    it("tests/lib/sb_helpers.sh (shared): all=true", () => {
      const r = classify("tests/lib/sb_helpers.sh");
      expect(r).toMatchObject({
        backend: "true",
        ui: "true",
        packaging: "true",
      });
    });
    it("plugin lib/.../awg_warp.uc: backend=T ui=F packaging=F", () => {
      const f = "plugins/awg_warp/lib/protocols/awg_warp.uc";
      const r = classify(f);
      expect(r).toMatchObject({
        backend: "true",
        ui: "false",
        packaging: "false",
      });
    });
    it("plugin htdocs/.../tab.js: backend=F ui=T packaging=F", () => {
      const f =
        "plugins/awg_warp/htdocs/luci-static/resources/view/singbox-ui/plugins/awg_warp/tab.js";
      const r = classify(f);
      expect(r).toMatchObject({
        backend: "false",
        ui: "true",
        packaging: "false",
      });
    });
    it("plugin root/awg-provision.sh: backend=T ui=F packaging=F", () => {
      const f = "plugins/awg_warp/root/usr/libexec/singbox-ui/awg-provision.sh";
      const r = classify(f);
      expect(r).toMatchObject({
        backend: "true",
        ui: "false",
        packaging: "false",
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

  for (const domain of ["backend", "ui", "packaging"]) {
    it(`changes job exports ${domain} as steps.agg.outputs.${domain}`, () => {
      const yml = readFileSync(BUILD_YML, "utf8");
      expect(yml).toMatch(new RegExp(`steps\\.agg\\.outputs\\.${domain}`));
    });
  }

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

  it("build.yml backend filter includes bbolt-client/", () => {
    const yml = readFileSync(BUILD_YML, "utf8");
    expect(yml).toContain("bbolt-client/**");
  });

  it("build.yml backend filter includes plugin lib/", () => {
    const yml = readFileSync(BUILD_YML, "utf8");
    expect(yml).toContain("plugins/awg_warp/lib/**");
  });

  it("build.yml backend filter includes plugin root/", () => {
    const yml = readFileSync(BUILD_YML, "utf8");
    expect(yml).toContain("plugins/awg_warp/root/**");
  });

  it("build.yml ui filter includes plugin htdocs/", () => {
    const yml = readFileSync(BUILD_YML, "utf8");
    expect(yml).toContain("plugins/awg_warp/htdocs/**");
  });
});
