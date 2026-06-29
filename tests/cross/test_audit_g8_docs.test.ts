import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { describe, expect, it } from "vitest";

// tests/cross/test_audit_g8_docs.sh
// Regression guard for audit group G8 (docs / i18n). Pins the documentation
// rewrites to the actual code so the docs cannot silently rot back to the
// superseded C3-era state.
//
//   13.1 — docs/protocol-descriptors.md describes the post-E2 registry-only
//          model: no legacy-switch / SSH narrative; every protocol named in
//          the require-list block exists as a lib/protocols/*.uc file.
//   13.5 — docs/uci-schema.md: vmess no longer appears in the
//          multiplex_enabled depends value (vmess dropped in E2).
//   13.3 — CHANGELOG.md records the luci-app-singbox-ui -> luci-singbox-ui
//          package rename (commit 3aa0ffe).
//   13.4 — README.md carries an English summary section.

const REPO = resolve(import.meta.dirname, "../..");
const DESC = join(REPO, "docs/protocol-descriptors.md");
const SCHEMA = join(REPO, "docs/uci-schema.md");
const CHANGELOG = join(REPO, "CHANGELOG.md");
const README = join(REPO, "README.md");
const PROTODIR = join(
  REPO,
  "singbox-ui/root/usr/share/singbox-ui/lib/builder/protocols",
);

describe("audit G8 docs / i18n", () => {
  it("all required doc files exist", () => {
    for (const f of [DESC, SCHEMA, CHANGELOG, README]) {
      expect(existsSync(f)).toBe(true);
    }
  });

  // ---------------------------------------------------------------------------
  // 13.1 — protocol-descriptors.md is the post-E2 registry-only doc
  // ---------------------------------------------------------------------------
  describe("13.1 protocol-descriptors.md is the post-E2 registry-only doc", () => {
    it("does NOT claim registry-first-then-fallback dispatch", () => {
      const doc = readFileSync(DESC, "utf8");
      expect(doc.toLowerCase()).not.toContain("consults the registry first");
    });

    it("does NOT describe a legacy switch fallback", () => {
      const doc = readFileSync(DESC, "utf8");
      expect(doc.toLowerCase()).not.toContain("otherwise the legacy");
    });

    it("does NOT reference the 'legacy dispatcher'", () => {
      const doc = readFileSync(DESC, "utf8");
      expect(doc.toLowerCase()).not.toContain("legacy dispatcher");
    });

    it("does NOT have a 'Migration plan' section", () => {
      const doc = readFileSync(DESC, "utf8");
      expect(doc).not.toMatch(/^## Migration plan/im);
    });

    it("does NOT reference a nonexistent SSH descriptor", () => {
      const doc = readFileSync(DESC, "utf8");
      expect(doc).not.toMatch(
        /protocols\.ssh|protocols\/ssh\.uc|SSH (outbound|descriptor)/i,
      );
    });

    it("states the registry-only model", () => {
      const doc = readFileSync(DESC, "utf8");
      expect(doc.toLowerCase()).toContain("registry-only");
    });

    it.each([
      "enum",
      "dynamic",
      "placeholder",
      "virtual",
      "values",
    ])("field vocabulary contains '%s' as a backtick code span", (kw) => {
      const doc = readFileSync(DESC, "utf8");
      expect(doc).toMatch(new RegExp(`\`${kw}[\`:]`));
    });

    it("explains values-as-combobox", () => {
      const doc = readFileSync(DESC, "utf8");
      expect(doc.toLowerCase()).toContain("combobox");
    });

    it("every protocols.* module named in require-list exists as a .uc file", () => {
      const doc = readFileSync(DESC, "utf8");
      // Find all protocols.<name> references
      const matches = [...doc.matchAll(/protocols\.([a-z0-9_]+)/g)];
      expect(matches.length).toBeGreaterThan(0);
      const mods = [...new Set(matches.map((m) => m[1]))];
      for (const mod of mods) {
        // registry and _shared are namespaces, not protocol files
        if (mod === "registry" || mod === "_shared") continue;
        const filepath = join(PROTODIR, `${mod}.uc`);
        expect(existsSync(filepath)).toBe(true);
      }
    });
  });

  // ---------------------------------------------------------------------------
  // 13.5 — vmess dropped from the multiplex_enabled depends value
  // ---------------------------------------------------------------------------
  describe("13.5 uci-schema.md multiplex_enabled depends drops vmess", () => {
    it("multiplex_enabled row exists in uci-schema.md", () => {
      const schema = readFileSync(SCHEMA, "utf8");
      const row = schema
        .split("\n")
        .find((l) => /^\| `multiplex_enabled`/.test(l));
      expect(row).toBeTruthy();
    });

    it("multiplex_enabled row does NOT list vmess", () => {
      const schema = readFileSync(SCHEMA, "utf8");
      const row = schema
        .split("\n")
        .find((l) => /^\| `multiplex_enabled`/.test(l));
      expect(row).toBeTruthy();
      expect(row).not.toContain("vmess");
    });

    it("multiplex_enabled row still documents vless/trojan/shadowsocks", () => {
      const schema = readFileSync(SCHEMA, "utf8");
      const row = schema
        .split("\n")
        .find((l) => /^\| `multiplex_enabled`/.test(l));
      expect(row).toBeTruthy();
      expect(row).toMatch(/vless.*trojan.*shadowsocks/);
    });
  });

  // ---------------------------------------------------------------------------
  // 13.3 — CHANGELOG records the rename
  // ---------------------------------------------------------------------------
  describe("13.3 CHANGELOG records the package rename", () => {
    it("mentions old package name luci-app-singbox-ui", () => {
      const cl = readFileSync(CHANGELOG, "utf8");
      expect(cl).toContain("luci-app-singbox-ui");
    });

    it("mentions new package name luci-singbox-ui", () => {
      const cl = readFileSync(CHANGELOG, "utf8");
      expect(cl).toContain("luci-singbox-ui");
    });

    it("references rename commit 3aa0ffe", () => {
      const cl = readFileSync(CHANGELOG, "utf8");
      expect(cl).toContain("3aa0ffe");
    });
  });

  // ---------------------------------------------------------------------------
  // 13.4 — README has an English summary covering the key operator caveats
  // ---------------------------------------------------------------------------
  describe("13.4 README carries an English summary with key caveats", () => {
    it("has an English section heading", () => {
      const readme = readFileSync(README, "utf8");
      expect(readme).toMatch(/## English/i);
    });

    it("English section has an install command (apk add)", () => {
      const readme = readFileSync(README, "utf8");
      expect(readme.toLowerCase()).toContain("apk add");
    });

    it("English section has the fw3 conflict warning", () => {
      const readme = readFileSync(README, "utf8");
      expect(readme).toMatch(/Conflicts with .firewall|fw3/i);
    });

    it("mentions the tproxy ip-rule prerequisite", () => {
      const readme = readFileSync(README, "utf8");
      expect(readme.toLowerCase()).toContain("ip rule");
    });
  });
});
