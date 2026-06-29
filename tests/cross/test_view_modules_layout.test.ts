import { execSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { describe, expect, it } from "vitest";

// tests/cross/test_view_modules_layout.sh
// Verifies the modularized view layout under htdocs/luci-static/resources/view/singbox-ui/.

const REPO = resolve(import.meta.dirname, "../..");
const SB_VIEW = join(
  REPO,
  "luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui",
);
const SB_LIB = join(REPO, "singbox-ui/root/usr/share/singbox-ui/lib");

const REQUIRED_FILES = [
  "main.js",
  "lib/rpc.js",
  "lib/common.js",
  "lib/plugins.js",
  "importers/inbound.js",
  "importers/outbound.js",
  "importers/transport.js",
  "tabs/inbounds.js",
  "tabs/outbounds.js",
  "tabs/route.js",
  "tabs/dns.js",
  "tabs/general.js",
  "tabs/monitoring.js",
  "tabs/plugins.js",
  "widgets/action-bar.js",
  "widgets/status-panel.js",
];

describe("test_view_modules_layout", () => {
  describe("required files exist", () => {
    for (const rel of REQUIRED_FILES) {
      it(`${rel} exists`, () => {
        expect(existsSync(join(SB_VIEW, rel))).toBe(true);
      });
    }
  });

  it("main.js must be small after the refactor (≤220 lines)", () => {
    const src = readFileSync(join(SB_VIEW, "main.js"), "utf8");
    const lines = src.split("\n").length;
    expect(lines).toBeLessThanOrEqual(220);
  });

  it("no leftover window.__sb_* globals in view tree", () => {
    const result = execSync(`grep -RHn "window\\.__sb" "${SB_VIEW}" || true`, {
      encoding: "utf8",
    });
    expect(result.trim()).toBe("");
  });

  it("no location.reload() calls in view tree (Phase C1)", () => {
    const result = execSync(
      `grep -RnE 'window\\.location\\.reload\\b|[^a-zA-Z_$]location\\.reload\\b' "${SB_VIEW}" || true`,
      { encoding: "utf8" },
    );
    expect(result.trim()).toBe("");
  });

  it("dead loadOutboundList alias must be removed from inbounds/outbounds (C2 D.1)", () => {
    const result = execSync(
      `grep -nE 'var[[:space:]]+loadOutboundList[[:space:]]*=[[:space:]]*SbCommon\\.loadOutboundList' ` +
        `"${SB_VIEW}/tabs/inbounds.js" "${SB_VIEW}/tabs/outbounds.js" || true`,
      { encoding: "utf8" },
    );
    expect(result.trim()).toBe("");
  });

  it("no setTimeout(fn, 0) in main.js (C2 D.4)", () => {
    const result = execSync(
      `grep -nE 'setTimeout\\(.*,[[:space:]]*0[[:space:]]*\\)' "${SB_VIEW}/main.js" || true`,
      { encoding: "utf8" },
    );
    expect(result.trim()).toBe("");
  });

  it("nft_rules present in builder/route/ruleset_remote.uc (descriptor-driven)", () => {
    const src = readFileSync(
      join(SB_LIB, "builder/route/ruleset_remote.uc"),
      "utf8",
    );
    expect(src).toContain("nft_rules");
  });

  describe("C2 E.1: action-bar Preview uses showJsonModal {error} shape", () => {
    const actionBar = readFileSync(
      join(SB_VIEW, "widgets/action-bar.js"),
      "utf8",
    );

    it("action-bar.js uses {error} shape in Preview", () => {
      expect(actionBar).toMatch(/\{ ?error/);
    });

    it("action-bar.js does not call ui.showModal directly for Preview generated config", () => {
      expect(actionBar).not.toMatch(
        /ui\.showModal\(.*_\('Preview generated config'\)/,
      );
    });
  });

  describe("C2 E.2: withBusy helper in lib/common.js", () => {
    const common = readFileSync(join(SB_VIEW, "lib/common.js"), "utf8");

    it("lib/common.js defines withBusy", () => {
      expect(common).toMatch(/function\s+withBusy\b/);
    });

    it("lib/common.js exports withBusy", () => {
      expect(common).toMatch(/withBusy:\s*withBusy/);
    });
  });

  it("C2 E.3: importers/inbound.js must not define fallbackCopy", () => {
    const src = readFileSync(join(SB_VIEW, "importers/inbound.js"), "utf8");
    const count = (src.match(/function fallbackCopy/g) ?? []).length;
    expect(count).toBe(0);
  });

  describe("C2 E.4: shared style.css", () => {
    it("style.css exists", () => {
      expect(existsSync(join(SB_VIEW, "style.css"))).toBe(true);
    });

    it("style.css is in the UI install manifest", () => {
      const manifest = readFileSync(
        join(REPO, "scripts/install-manifest-luci-app-singbox-ui.txt"),
        "utf8",
      );
      expect(manifest).toContain("style.css");
    });
  });

  it("D1.8: build_constructor_for dispatcher region ≤14 lines in outbound.uc", () => {
    const src = readFileSync(join(SB_LIB, "outbound.uc"), "utf8");
    const lines = src.split("\n");

    // Find start: line with `^function build_constructor_for`
    const startIdx = lines.findIndex((l) =>
      /^function build_constructor_for/.test(l),
    );
    expect(startIdx).toBeGreaterThan(-1);

    // Find end: next line that starts with `^function` after startIdx
    let endIdx = -1;
    for (let i = startIdx + 1; i < lines.length; i++) {
      if (/^function /.test(lines[i])) {
        endIdx = i;
        break;
      }
    }
    expect(endIdx).toBeGreaterThan(startIdx);

    const regionSize = endIdx - startIdx;
    expect(regionSize).toBeLessThanOrEqual(14);
  });

  describe("D2.9: no hand-coded depends per-proxy-protocol in tabs/", () => {
    const outboundsSrc = readFileSync(
      join(SB_VIEW, "tabs/outbounds.js"),
      "utf8",
    );
    const inboundsSrc = readFileSync(join(SB_VIEW, "tabs/inbounds.js"), "utf8");

    const outboundProxies = [
      "ssh",
      "trojan",
      "shadowsocks",
      "vless",
      "vmess",
      "hysteria2",
      "tuic",
      "anytls",
    ];
    for (const proto of outboundProxies) {
      it(`no depends('type','${proto}') in tabs/outbounds.js`, () => {
        const re = new RegExp(
          `depends\\(['"](type)['"],[\\s]*['"]${proto}['"]\\)`,
        );
        expect(outboundsSrc).not.toMatch(re);
      });
    }

    const inboundProxies = [
      "trojan",
      "shadowsocks",
      "vless",
      "vmess",
      "hysteria2",
    ];
    for (const proto of inboundProxies) {
      it(`no depends('protocol','${proto}') in tabs/inbounds.js`, () => {
        const re = new RegExp(
          `depends\\(['"](protocol)['"],[\\s]*['"]${proto}['"]\\)`,
        );
        expect(inboundsSrc).not.toMatch(re);
      });
    }
  });
});
