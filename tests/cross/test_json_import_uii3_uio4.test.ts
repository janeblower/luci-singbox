import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import vm from "node:vm";
import { describe, expect, it } from "vitest";

const REPO = resolve(import.meta.dirname, "../..");
const SB_VIEW = join(
  REPO,
  "luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui",
);

function buildSandbox() {
  const sandbox: Record<string, any> = {
    form: {
      Map: () => {},
      GridSection: () => {},
      NamedSection: () => {},
      Value: () => {},
      Flag: () => {},
      ListValue: () => {},
      DynamicList: () => {},
      TextValue: () => {},
    },
    uci: {
      get: () => null,
      set: () => null,
      add: () => null,
      sections: () => [],
    },
    ui: {
      showModal: () => null,
      hideModal: () => null,
      createHandlerFn: () => () => {},
    },
    rpc: { declare: () => () => Promise.resolve() },
    widgets: { DeviceSelect: () => {} },
    view: { extend: (o: any) => o },
    _: (s: any) => s,
    E: () => ({ appendChild: () => null }),
    Promise,
    console,
    setTimeout,
    atob: (s: string) => Buffer.from(s, "base64").toString("utf8"),
  };
  sandbox.window = sandbox;

  function loadModule(filePath: string) {
    const msrc = readFileSync(filePath, "utf8");
    const mbody = msrc
      .replace(/^'use strict';\s*/, "")
      .replace(/^'require [^']+';\s*/gm, "")
      .replace(
        /return L\.Class\.extend\((\{[\s\S]*\})\);?\s*$/,
        "__moduleExports = $1;",
      );
    const mctx = vm.createContext(
      Object.assign({}, sandbox, { __moduleExports: null }),
    );
    vm.runInContext(`(function() {${mbody}})();`, mctx, {
      filename: filePath.split("/").pop(),
    });
    return (mctx as any).__moduleExports;
  }

  const viewDir = SB_VIEW;
  sandbox.SbCommon = loadModule(join(viewDir, "lib/common.js"));
  sandbox.SbTransport = loadModule(join(viewDir, "importers/transport.js"));
  sandbox.SbImpInbound = loadModule(join(viewDir, "importers/inbound.js"));
  sandbox.SbImpOutbound = loadModule(join(viewDir, "importers/outbound.js"));

  return sandbox as any;
}

describe("uii3-uio4: reality empty array guard + parseIntField dedup", () => {
  let ctx: any;
  let fnIn: any;
  let fnOut: any;

  it("loads sandbox and exports functions", () => {
    ctx = buildSandbox();
    fnIn = ctx.SbImpInbound?.jsonImportInbound;
    fnOut = ctx.SbImpOutbound?.jsonImportOutbound;
    expect(typeof fnIn).toBe("function");
    expect(typeof fnOut).toBe("function");
  });

  describe("uii-3: inbound reality short_id empty array guard", () => {
    it("empty reality short_id array does not write literal 'undefined'", () => {
      ctx = ctx ?? buildSandbox();
      fnIn = fnIn ?? ctx.SbImpInbound?.jsonImportInbound;
      const got = fnIn({
        type: "vless",
        listen: "::",
        listen_port: 443,
        users: [{ uuid: "u1", flow: "xtls-rprx-vision" }],
        tls: {
          enabled: true,
          server_name: "example.com",
          reality: {
            enabled: true,
            private_key: "pk",
            short_id: [],
            handshake: { server: "www.example.com", server_port: 443 },
          },
        },
      });
      expect(got.ok).toBe(true);
      expect(got.fields.reality_short_id).toBeUndefined();
      // Regression guard: the field must never carry the literal string
      // "undefined" (the pre-fix behavior wrote String(short_id[0]) for []).
      expect(got.fields.reality_short_id).not.toBe("undefined");
    });

    it("non-empty reality short_id array correctly sets first element", () => {
      ctx = ctx ?? buildSandbox();
      fnIn = fnIn ?? ctx.SbImpInbound?.jsonImportInbound;
      const got = fnIn({
        type: "vless",
        listen: "::",
        listen_port: 443,
        users: [{ uuid: "u1" }],
        tls: {
          reality: {
            enabled: true,
            private_key: "pk",
            short_id: ["ab12", "cd34"],
            handshake: { server: "www.example.com", server_port: 443 },
          },
        },
      });
      expect(got.ok).toBe(true);
      expect(got.fields.reality_short_id).toBe("ab12");
    });
  });

  describe("uio-4: parseIntField shared in transport.js", () => {
    it("inbound parseIntField is called via SbTransport", () => {
      ctx = ctx ?? buildSandbox();
      fnIn = fnIn ?? ctx.SbImpInbound?.jsonImportInbound;
      const got = fnIn({
        type: "shadowsocks",
        listen: "::",
        listen_port: "8388",
        method: "aes-256-gcm",
        password: "p",
      });
      expect(got.ok).toBe(true);
      expect(got.fields.listen_port).toBe(8388);
    });

    it("outbound parseIntField is called via SbTransport", () => {
      ctx = ctx ?? buildSandbox();
      fnOut = fnOut ?? ctx.SbImpOutbound?.jsonImportOutbound;
      const got = fnOut({
        type: "vless",
        server: "a.b",
        server_port: "443",
        uuid: "uu",
        tls: { enabled: true, server_name: "a.b" },
      });
      expect(got.ok).toBe(true);
      expect(got.fields.server_port).toBe(443);
    });

    it("transport exports parseIntField", () => {
      ctx = ctx ?? buildSandbox();
      expect(typeof ctx.SbTransport?.parseIntField).toBe("function");
    });

    it("both importers use shared parseIntField for validation", () => {
      ctx = ctx ?? buildSandbox();
      fnIn = fnIn ?? ctx.SbImpInbound?.jsonImportInbound;
      fnOut = fnOut ?? ctx.SbImpOutbound?.jsonImportOutbound;

      const inboundBad = fnIn({
        type: "shadowsocks",
        listen: "::",
        listen_port: "eighty",
        method: "aes-256-gcm",
        password: "p",
      });
      expect(inboundBad.ok).toBe(false);
      expect(inboundBad.errors[0]).toContain("Invalid port");

      const outboundBad = fnOut({
        type: "vless",
        server: "a.b",
        server_port: "seventy",
        uuid: "uu",
      });
      expect(outboundBad.ok).toBe(false);
      expect(outboundBad.errors[0]).toContain("Invalid port");
    });
  });

  describe("uii-1: tun inbound is rejected (no backend builder)", () => {
    it("jsonImportInbound rejects type=tun with a clear error", () => {
      ctx = ctx ?? buildSandbox();
      fnIn = fnIn ?? ctx.SbImpInbound?.jsonImportInbound;
      const got = fnIn({ type: "tun", interface_name: "tun0", mtu: 1500 });
      expect(got.ok).toBe(false);
      expect(got.errors[0]).toContain("tun");
    });
  });

  describe("uio-1: vmess:// share-link pre-fill", () => {
    it("decodes v2rayN base64 JSON into UCI fields", () => {
      ctx = ctx ?? buildSandbox();
      const link = ctx.SbImpOutbound.shareLinkImport;
      const v2rayN = {
        v: "2",
        ps: "node",
        add: "e.com",
        port: "443",
        id: "11111111-2222-3333-4444-555555555555",
        aid: "0",
        net: "ws",
        path: "/p",
        host: "h.com",
        tls: "tls",
        sni: "s.com",
        scy: "auto",
      };
      const url = `vmess://${Buffer.from(JSON.stringify(v2rayN)).toString("base64")}`;
      const r = link(url);
      expect(r.ok).toBe(true);
      expect(r.fields.server).toBe("e.com");
      expect(r.fields.server_port).toBe(443);
      expect(r.fields.server_uuid).toBe(v2rayN.id);
      expect(r.fields.vmess_security).toBe("auto");
      expect(r.fields.transport).toBe("ws");
      expect(r.fields.transport_path).toBe("/p");
      expect(r.fields.transport_host).toBe("h.com");
      expect(r.fields.security).toBe("tls");
      expect(r.fields.tls_server_name).toBe("s.com");
    });

    it("rejects a vmess link missing server/port/uuid", () => {
      ctx = ctx ?? buildSandbox();
      const link = ctx.SbImpOutbound.shareLinkImport;
      const url = `vmess://${Buffer.from(JSON.stringify({ add: "e.com" })).toString("base64")}`;
      const r = link(url);
      expect(r.ok).toBe(false);
    });
  });

  describe("uio-2: shadowsocks share-link rejects credential-less links", () => {
    it("rejects ss://host:port#tag (no method/password)", () => {
      ctx = ctx ?? buildSandbox();
      const link = ctx.SbImpOutbound.shareLinkImport;
      const r = link("ss://e.com:8388#tag");
      expect(r.ok).toBe(false);
      expect(r.errors[0]).toContain("method/password");
    });

    it("still accepts a credentialed ss link", () => {
      ctx = ctx ?? buildSandbox();
      const link = ctx.SbImpOutbound.shareLinkImport;
      const userinfo = Buffer.from("aes-256-gcm:secret").toString("base64");
      const r = link(`ss://${userinfo}@e.com:8388#tag`);
      expect(r.ok).toBe(true);
      expect(r.fields.shadowsocks_method).toBe("aes-256-gcm");
      expect(r.fields.server_password).toBe("secret");
    });
  });

  describe("uio-3: vless reality gate (mirror h_tls_security)", () => {
    it("security=reality WITHOUT pbk degrades to plain TLS (no short_id)", () => {
      ctx = ctx ?? buildSandbox();
      const link = ctx.SbImpOutbound.shareLinkImport;
      const r = link(
        "vless://11111111-2222-3333-4444-555555555555@h.com:443?security=reality&sid=ab12#n",
      );
      expect(r.ok).toBe(true);
      expect(r.fields.security).toBe("tls");
      expect(r.fields.reality_short_id).toBeUndefined();
      expect(r.fields.reality_public_key).toBeUndefined();
    });

    it("security=reality WITH pbk keeps reality + short_id", () => {
      ctx = ctx ?? buildSandbox();
      const link = ctx.SbImpOutbound.shareLinkImport;
      const r = link(
        "vless://11111111-2222-3333-4444-555555555555@h.com:443?security=reality&pbk=PUBKEY&sid=ab12#n",
      );
      expect(r.ok).toBe(true);
      expect(r.fields.security).toBe("reality");
      expect(r.fields.reality_public_key).toBe("PUBKEY");
      expect(r.fields.reality_short_id).toBe("ab12");
    });
  });
});
