import { describe, expect, it } from "bun:test";
import { resolve } from "node:path";
import { loadLuciModule } from "../helpers/luci.ts";

// tests/test_audit_9_3.sh — regression for audit 9.3.
// The ss:// share-link regex lacked a query-string group, so SIP002 links that
// carry ?plugin=name;opts before the #tag failed to match at all and the
// importer returned "Cannot parse shadowsocks URL".
// Exercises importers/outbound.shareLinkImport and asserts SIP002 plugin parsing.

const VIEW_ROOT = resolve(
  import.meta.dir,
  "../../luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui",
);
const OUTBOUND_JS = resolve(VIEW_ROOT, "importers/outbound.js");

// atob in Bun is a global; provide it to the vm sandbox explicitly.
function nodeAtob(s: string): string {
  return Buffer.from(s, "base64").toString("binary");
}

const { exports: mod } = loadLuciModule(OUTBOUND_JS, {
  _: (s: unknown) => s,
  atob: nodeAtob,
  // stub required modules (stripped by loadLuciModule regex; vars resolve as undefined)
  uci: {},
  ui: {},
  SbImpInbound: {},
  SbTransport: {},
});

describe("audit 9.3 — SIP002 ss:// ?plugin= share-link parsing", () => {
  it("exports shareLinkImport", () => {
    expect(typeof mod.shareLinkImport).toBe("function");
  });

  describe("SIP002 with ?plugin=name;opts before #tag", () => {
    const r = mod.shareLinkImport(
      "ss://aes-256-gcm:secret@ss.example:8388?plugin=obfs-local;obfs=http;obfs-host=cdn.example#ss-plug",
    );

    it("SIP002 plugin link parses (ok=true, type=shadowsocks)", () => {
      expect(r.ok && r.fields.type === "shadowsocks").toBe(true);
    });

    it("SIP002 server", () => {
      expect(r.fields.server).toBe("ss.example");
    });

    it("SIP002 port", () => {
      expect(r.fields.server_port).toBe(8388);
    });

    it("SIP002 method", () => {
      expect(r.fields.shadowsocks_method).toBe("aes-256-gcm");
    });

    it("SIP002 password", () => {
      expect(r.fields.server_password).toBe("secret");
    });

    it("SIP002 plugin name (matches backend field)", () => {
      expect(r.fields.plugin).toBe("obfs-local");
    });

    it('SIP002 plugin_opts (remainder after first ";")', () => {
      expect(r.fields.plugin_opts).toBe("obfs=http;obfs-host=cdn.example");
    });
  });

  describe("?plugin=name with NO opts", () => {
    const r = mod.shareLinkImport(
      "ss://aes-256-gcm:pw@ss.example:8388?plugin=v2ray-plugin#x",
    );

    it("plugin-only name", () => {
      expect(r.ok && r.fields.plugin === "v2ray-plugin").toBe(true);
    });

    it("plugin-only no opts (plugin_opts absent)", () => {
      expect("plugin_opts" in r.fields).toBe(false);
    });
  });

  describe("base64 userinfo + ?plugin=", () => {
    const b64 = Buffer.from("aes-256-gcm:secret", "utf8").toString("base64");
    const r = mod.shareLinkImport(
      `ss://${b64}@ss.example:8388?plugin=obfs-local;obfs=tls#b64plug`,
    );

    it("b64 userinfo + plugin method", () => {
      expect(r.fields.shadowsocks_method).toBe("aes-256-gcm");
    });

    it("b64 userinfo + plugin password", () => {
      expect(r.fields.server_password).toBe("secret");
    });

    it("b64 userinfo + plugin name", () => {
      expect(r.fields.plugin).toBe("obfs-local");
    });

    it("b64 userinfo + plugin opts", () => {
      expect(r.fields.plugin_opts).toBe("obfs=tls");
    });
  });

  describe("IPv6 bracket host + ?plugin=", () => {
    const r = mod.shareLinkImport(
      "ss://aes-256-gcm:pw@[2001:db8::9]:8388?plugin=obfs-local;obfs=http#v6",
    );

    it("IPv6 host + plugin ok and server", () => {
      expect(r.ok && r.fields.server === "[2001:db8::9]").toBe(true);
    });

    it("IPv6 host + plugin port", () => {
      expect(r.fields.server_port).toBe(8388);
    });

    it("IPv6 host + plugin name", () => {
      expect(r.fields.plugin).toBe("obfs-local");
    });
  });

  describe("plain link without plugin (no regression)", () => {
    const r = mod.shareLinkImport(
      "ss://aes-128-gcm:mypass@ss2.example:8388#ss2",
    );

    it("plain link parses", () => {
      expect(r.ok && r.fields.shadowsocks_method === "aes-128-gcm").toBe(true);
    });

    it("plain link no plugin key", () => {
      expect("plugin" in r.fields).toBe(false);
    });

    it("plain link no plugin_opts key", () => {
      expect("plugin_opts" in r.fields).toBe(false);
    });
  });
});
