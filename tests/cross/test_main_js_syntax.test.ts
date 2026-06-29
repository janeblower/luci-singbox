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

// tests/cross/test_main_js_syntax.sh — syntax check + keyword grep of main.js
// and related modular tab files.

const REPO = resolve(import.meta.dirname, "../..");
const SB_UI_HTDOCS = join(REPO, "luci-app-singbox-ui/htdocs");
const SB_VIEW = join(SB_UI_HTDOCS, "luci-static/resources/view/singbox-ui");
const SB_LIB = join(REPO, "singbox-ui/root/usr/share/singbox-ui/lib");
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

  describe("declares all expected requires", () => {
    const src = readFileSync(JS, "utf8");

    it("requires view", () => {
      expect(src).toContain("'require view'");
    });
    it("requires form", () => {
      expect(src).toContain("'require form'");
    });
    it("requires uci", () => {
      expect(src).toContain("'require uci'");
    });
    it("requires ui", () => {
      expect(src).toContain("'require ui'");
    });
    it("requires tools.widgets as widgets", () => {
      expect(src).toContain("'require tools.widgets as widgets'");
    });
  });

  describe("references input UCI sections (in tab modules)", () => {
    it("fakeip in tabs/dns.js", () => {
      const dns = readFileSync(join(SB_VIEW, "tabs/dns.js"), "utf8");
      expect(dns).toContain("fakeip");
    });

    it("tproxy in tabs/inbounds.js", () => {
      const inbounds = readFileSync(join(SB_VIEW, "tabs/inbounds.js"), "utf8");
      expect(inbounds).toContain("tproxy");
    });
  });

  describe("references all three output GridSections", () => {
    const src = readFileSync(JS, "utf8");
    const dnsTab = readFileSync(join(SB_VIEW, "tabs/dns.js"), "utf8");
    const routeTab = readFileSync(join(SB_VIEW, "tabs/route.js"), "utf8");

    it("GridSection in main.js or tabs/dns.js", () => {
      expect(
        src.includes("GridSection") || dnsTab.includes("GridSection"),
      ).toBe(true);
    });
    it("outbound section type in tabs/route.js", () => {
      expect(routeTab).toContain("'outbound'");
    });
    it("ruleset section type in tabs/route.js", () => {
      expect(routeTab).toContain("'ruleset'");
    });
    it("route_rule section type in tabs/route.js", () => {
      expect(routeTab).toContain("'route_rule'");
    });
    it("modaltitle in main.js or tabs/route.js or tabs/dns.js", () => {
      expect(
        src.includes("modaltitle") ||
          routeTab.includes("modaltitle") ||
          dnsTab.includes("modaltitle"),
      ).toBe(true);
    });
  });

  describe("references new outbound types (merged type field)", () => {
    const outboundsTab = readFileSync(
      join(SB_VIEW, "tabs/outbounds.js"),
      "utf8",
    );
    const src = readFileSync(JS, "utf8");

    it("type=vless in tabs/outbounds.js", () => {
      expect(outboundsTab).toContain("'vless'");
    });
    it("type=subscription in tabs/outbounds.js", () => {
      expect(outboundsTab).toContain("'subscription'");
    });
    it("openShareLinkModal in tabs/outbounds.js", () => {
      expect(outboundsTab).toContain("openShareLinkModal");
    });
    it("sub_url field in tabs/outbounds.js", () => {
      expect(outboundsTab).toContain("sub_url");
    });
    it("sub_user_agent field in tabs/outbounds.js", () => {
      expect(outboundsTab).toContain("sub_user_agent");
    });
    it("sub_update_via must be removed from tabs/outbounds.js", () => {
      expect(outboundsTab).not.toContain("sub_update_via");
    });
    it("sub_interval field in tabs/outbounds.js", () => {
      expect(outboundsTab).toContain("sub_interval");
    });
    it("no legacy proxy_type in main.js", () => {
      expect(src).not.toContain("proxy_type");
    });
    it("no legacy json outbound type in main.js", () => {
      expect(src).not.toContain("'json'");
    });
  });

  describe("references ruleset fields (descriptor-driven)", () => {
    it("nft_rules in builder/route/ruleset_remote.uc", () => {
      const rsRemote = readFileSync(
        join(SB_LIB, "builder/route/ruleset_remote.uc"),
        "utf8",
      );
      expect(rsRemote).toContain("nft_rules");
    });
    it("update_interval in builder/route/ruleset_remote.uc", () => {
      const rsRemote = readFileSync(
        join(SB_LIB, "builder/route/ruleset_remote.uc"),
        "utf8",
      );
      expect(rsRemote).toContain("update_interval");
    });
    it("applyMaterialized in tabs/route.js", () => {
      const routeTab = readFileSync(join(SB_VIEW, "tabs/route.js"), "utf8");
      expect(routeTab).toContain("applyMaterialized");
    });
  });

  describe("references DNS tab sections", () => {
    const dnsTab = readFileSync(join(SB_VIEW, "tabs/dns.js"), "utf8");
    const src = readFileSync(JS, "utf8");

    it("dns_server section type in tabs/dns.js", () => {
      expect(dnsTab).toContain("'dns_server'");
    });
    it("dns_rule section type in tabs/dns.js", () => {
      expect(dnsTab).toContain("'dns_rule'");
    });
    it("data-tab dns marker in main.js", () => {
      expect(src).toContain("data-tab");
      expect(src).toContain("dns");
    });
    it("applyMaterialized in tabs/dns.js", () => {
      expect(dnsTab).toContain("applyMaterialized");
    });
    it("dnsSchema in tabs/dns.js", () => {
      expect(dnsTab).toContain("dnsSchema");
    });
    it("default_resolver in tabs/dns.js", () => {
      expect(dnsTab).toContain("'default_resolver'");
    });
  });

  describe("references Monitoring tab", () => {
    const src = readFileSync(JS, "utf8");
    const libRpcPath = join(SB_VIEW, "lib/rpc.js");

    it("buildMonitoring in main.js", () => {
      expect(src).toContain("buildMonitoring");
    });
    it("lib/rpc.js exists", () => {
      expect(existsSync(libRpcPath)).toBe(true);
    });
    it("callClashGet wrapper in lib/rpc.js", () => {
      const rpc = readFileSync(libRpcPath, "utf8");
      expect(rpc).toContain("callClashGet");
    });
    it("callClashMutate wrapper in lib/rpc.js", () => {
      const rpc = readFileSync(libRpcPath, "utf8");
      expect(rpc).toContain("callClashMutate");
    });
    it("clash_get method in lib/rpc.js", () => {
      const rpc = readFileSync(libRpcPath, "utf8");
      expect(rpc).toContain("clash_get");
    });
    it("clash_mutate method in lib/rpc.js", () => {
      const rpc = readFileSync(libRpcPath, "utf8");
      expect(rpc).toContain("clash_mutate");
    });
    it("no legacy clash_request in lib/rpc.js", () => {
      const rpc = readFileSync(libRpcPath, "utf8");
      expect(rpc).not.toContain("clash_request");
    });
    it("data-tab monitoring marker in main.js", () => {
      expect(src).toContain("monitoring");
    });
  });

  describe("has sub-tab data-tab markers", () => {
    const src = readFileSync(JS, "utf8");

    it("data-tab outbounds marker", () => {
      expect(src).toContain("outbounds");
    });
    it("data-tab rulesets marker", () => {
      expect(src).toContain("rulesets");
    });
    it("data-tab routerules marker", () => {
      expect(src).toContain("routerules");
    });
  });

  describe("has handleSaveApply via ui.changes.apply", () => {
    const src = readFileSync(JS, "utf8");
    const generalTab = readFileSync(join(SB_VIEW, "tabs/general.js"), "utf8");

    it("handleSaveApply in main.js", () => {
      expect(src).toContain("handleSaveApply");
    });
    it("ui.changes.apply in main.js", () => {
      expect(src).toContain("ui.changes.apply");
    });
    it("enabled flag in main.js or tabs/general.js", () => {
      expect(
        src.includes("'enabled'") || generalTab.includes("'enabled'"),
      ).toBe(true);
    });
  });

  describe("references General tab sections", () => {
    const generalTab = readFileSync(join(SB_VIEW, "tabs/general.js"), "utf8");
    const src = readFileSync(JS, "utf8");

    it("cache section type in tabs/general.js", () => {
      expect(generalTab).toContain("'cache'");
    });
    it("log section type in tabs/general.js", () => {
      expect(generalTab).toContain("'log'");
    });
    it("data-tab general marker in main.js", () => {
      expect(src).toContain("general");
    });
  });
});
