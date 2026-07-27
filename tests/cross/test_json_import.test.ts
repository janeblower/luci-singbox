import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import vm from "node:vm";
import { describe, expect, it } from "vitest";

// tests/cross/test_json_import.sh — drives the JSON-import parser in main.js
// through node. Skips when node is unavailable (node IS available in bun test context).

const REPO = resolve(import.meta.dirname, "../..");
const _SB_UI_ROOT = join(REPO, "luci-app-singbox-ui/root");
const SB_UI_HTDOCS = join(REPO, "luci-app-singbox-ui/htdocs");
const SB_VIEW = join(SB_UI_HTDOCS, "luci-static/resources/view/singbox-ui");
const JS = join(SB_VIEW, "main.js");

// Build a sandbox + load importers from view modules (mirrors the node script in the .sh)
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
    // vmess:// links are base64(JSON) — the share-link branch decodes them.
    atob: (b: string) => Buffer.from(b, "base64").toString("utf8"),
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
  sandbox.SbRpc = {
    callRefresh: () => Promise.resolve(),
    callRestart: () => Promise.resolve(),
    callStatus: () => Promise.resolve(),
    callReadConfig: () => Promise.resolve(),
    callClashGet: () => Promise.resolve(),
    callClashMutate: () => Promise.resolve(),
    callDhcpLeases: () => Promise.resolve(),
  };
  sandbox.SbCommon = loadModule(join(viewDir, "lib/common.js"));
  sandbox.SbTransport = loadModule(join(viewDir, "importers/transport.js"));
  sandbox.SbImpInbound = loadModule(join(viewDir, "importers/inbound.js"));
  sandbox.SbImpOutbound = loadModule(join(viewDir, "importers/outbound.js"));

  const src = readFileSync(JS, "utf8");
  const body = src
    .replace(/^'use strict';\s*/, "")
    .replace(/^'require [^']+';\s*/gm, "")
    .replace(/return view\.extend\(\{[\s\S]*\}\);?\s*$/, "");

  const ctx = vm.createContext(sandbox);
  vm.runInContext(`(function() {${body}})();`, ctx, { filename: "main.js" });
  return ctx as any;
}

describe("test_json_import", () => {
  it("main.js exists", () => {
    expect(existsSync(JS)).toBe(true);
  });

  let ctx: any;
  let fn: any;
  let fnOut: any;

  it("loads sandbox and exports jsonImportInbound / jsonImportOutbound", () => {
    ctx = buildSandbox();
    fn = ctx.SbImpInbound?.jsonImportInbound;
    fnOut = ctx.SbImpOutbound?.jsonImportOutbound;
    expect(typeof fn).toBe("function");
    expect(typeof fnOut).toBe("function");
  });

  describe("jsonImportInbound", () => {
    it("shadowsocks inbound", () => {
      ctx = ctx ?? buildSandbox();
      fn = fn ?? ctx.SbImpInbound?.jsonImportInbound;
      const got = fn({
        type: "shadowsocks",
        tag: "ss",
        listen: "::",
        listen_port: 8388,
        method: "aes-256-gcm",
        password: "p",
      });
      expect(got).toEqual({
        ok: true,
        errors: [],
        fields: {
          protocol: "shadowsocks",
          listen: "::",
          listen_port: 8388,
          shadowsocks_method: "aes-256-gcm",
          server_password: "p",
        },
      });
    });

    it("tun inbound is rejected (no backend builder; uii-1) and does not throw", () => {
      ctx = ctx ?? buildSandbox();
      fn = fn ?? ctx.SbImpInbound?.jsonImportInbound;
      // tun has no backend builder, so the importer now rejects it outright
      // rather than creating a phantom section generate.uc silently drops. The
      // malformed (numeric/null) address elements must still not throw — the
      // rejection returns a clean structured error.
      const got = fn({
        type: "tun",
        tag: "tun0",
        interface_name: "tun0",
        address: [123, null, "10.0.0.1/24", "fd00::1/64"],
      });
      expect(got.ok).toBe(false);
      expect(got.errors[0]).toContain("tun");
    });

    it("shadowsocks inbound multi-user", () => {
      ctx = ctx ?? buildSandbox();
      fn = fn ?? ctx.SbImpInbound?.jsonImportInbound;
      const got = fn({
        type: "shadowsocks",
        tag: "ss",
        listen: "::",
        listen_port: 8388,
        method: "2022-blake3-aes-128-gcm",
        users: [
          { name: "alice", password: "pw1" },
          { name: "bob", password: "pw2" },
        ],
      });
      expect(got).toEqual({
        ok: true,
        errors: [],
        fields: {
          protocol: "shadowsocks",
          listen: "::",
          listen_port: 8388,
          shadowsocks_method: "2022-blake3-aes-128-gcm",
          ss_user: ["alice:pw1", "bob:pw2"],
        },
      });
    });

    it("outbound JSON rejected", () => {
      ctx = ctx ?? buildSandbox();
      fn = fn ?? ctx.SbImpInbound?.jsonImportInbound;
      const got = fn({
        type: "shadowsocks",
        server: "a.b",
        server_port: 8388,
        password: "p",
      });
      expect(got).toEqual({
        ok: false,
        errors: [
          'Looks like an outbound (has "server" without "listen"). Use the outbound importer.',
        ],
        fields: {},
      });
    });

    it("unknown type rejected", () => {
      ctx = ctx ?? buildSandbox();
      fn = fn ?? ctx.SbImpInbound?.jsonImportInbound;
      const got = fn({ type: "wireguard" });
      expect(got).toEqual({
        ok: false,
        errors: ["Unknown inbound type: wireguard"],
        fields: {},
      });
    });

    it("missing type rejected", () => {
      ctx = ctx ?? buildSandbox();
      fn = fn ?? ctx.SbImpInbound?.jsonImportInbound;
      const got = fn({ listen: "::", listen_port: 53 });
      expect(got).toEqual({
        ok: false,
        errors: ['Missing "type" field'],
        fields: {},
      });
    });

    it("vless with reality TLS", () => {
      ctx = ctx ?? buildSandbox();
      fn = fn ?? ctx.SbImpInbound?.jsonImportInbound;
      const got = fn({
        type: "vless",
        listen: "::",
        listen_port: 443,
        users: [{ uuid: "u1", flow: "xtls-rprx-vision" }],
        tls: {
          enabled: true,
          server_name: "cdn.example.com",
          reality: {
            enabled: true,
            private_key: "pk",
            short_id: ["ab12"],
            handshake: { server: "www.example.com", server_port: 443 },
          },
        },
      });
      expect(got).toEqual({
        ok: true,
        errors: [],
        fields: {
          protocol: "vless",
          listen: "::",
          listen_port: 443,
          server_uuid: "u1",
          vless_flow: "xtls-rprx-vision",
          tls_enabled: "1",
          reality_enabled: "1",
          tls_server_name: "cdn.example.com",
          reality_private_key: "pk",
          reality_short_id: "ab12",
          reality_handshake_server: "www.example.com",
          reality_handshake_server_port: "443",
        },
      });
    });

    it("hysteria2 inbound with obfs", () => {
      ctx = ctx ?? buildSandbox();
      fn = fn ?? ctx.SbImpInbound?.jsonImportInbound;
      const got = fn({
        type: "hysteria2",
        listen: "::",
        listen_port: 8443,
        users: [{ name: "u", password: "pw" }],
        up_mbps: 100,
        down_mbps: 50,
        obfs: { type: "salamander", password: "op" },
      });
      expect(got).toEqual({
        ok: true,
        errors: [],
        fields: {
          protocol: "hysteria2",
          listen: "::",
          listen_port: 8443,
          server_password: "pw",
          obfs_type: "salamander",
          obfs_password: "op",
          up_mbps: "100",
          down_mbps: "50",
        },
      });
    });

    it("vless inbound multi-user with per-user flow", () => {
      ctx = ctx ?? buildSandbox();
      fn = fn ?? ctx.SbImpInbound?.jsonImportInbound;
      const got = fn({
        type: "vless",
        listen: "::",
        listen_port: 4443,
        users: [
          { name: "alice", uuid: "uuid-a", flow: "xtls-rprx-vision" },
          { name: "bob", uuid: "uuid-b" },
        ],
      });
      expect(got).toEqual({
        ok: true,
        errors: [],
        fields: {
          protocol: "vless",
          listen: "::",
          listen_port: 4443,
          inbound_user: ["alice:uuid-a:xtls-rprx-vision", "bob:uuid-b"],
        },
      });
    });

    it("inbound rejects mixed (builder lacks support)", () => {
      ctx = ctx ?? buildSandbox();
      fn = fn ?? ctx.SbImpInbound?.jsonImportInbound;
      const got = fn({ type: "mixed", listen: "::", listen_port: 8080 });
      expect(got).toEqual({
        ok: false,
        errors: ["Unknown inbound type: mixed"],
        fields: {},
      });
    });

    it("inbound non-numeric listen_port rejected", () => {
      ctx = ctx ?? buildSandbox();
      fn = fn ?? ctx.SbImpInbound?.jsonImportInbound;
      const got = fn({
        type: "shadowsocks",
        listen: "::",
        listen_port: "eight",
        method: "aes-256-gcm",
        password: "p",
      });
      expect(got).toEqual({
        ok: false,
        errors: ["Invalid port: eight"],
        fields: {},
      });
    });

    it("inbound out-of-range listen_port rejected", () => {
      ctx = ctx ?? buildSandbox();
      fn = fn ?? ctx.SbImpInbound?.jsonImportInbound;
      const got = fn({
        type: "shadowsocks",
        listen: "::",
        listen_port: 70000,
        method: "aes-256-gcm",
        password: "p",
      });
      expect(got).toEqual({
        ok: false,
        errors: ["Invalid port: 70000"],
        fields: {},
      });
    });

    it("inbound listen_port with trailing garbage rejected", () => {
      ctx = ctx ?? buildSandbox();
      fn = fn ?? ctx.SbImpInbound?.jsonImportInbound;
      const got = fn({
        type: "shadowsocks",
        listen: "::",
        listen_port: "80abc",
        method: "aes-256-gcm",
        password: "p",
      });
      expect(got).toEqual({
        ok: false,
        errors: ["Invalid port: 80abc"],
        fields: {},
      });
    });

    it("inbound numeric listen_port still imports", () => {
      ctx = ctx ?? buildSandbox();
      fn = fn ?? ctx.SbImpInbound?.jsonImportInbound;
      const got = fn({
        type: "shadowsocks",
        listen: "::",
        listen_port: 8388,
        method: "aes-256-gcm",
        password: "p",
      });
      expect(got).toEqual({
        ok: true,
        errors: [],
        fields: {
          protocol: "shadowsocks",
          listen: "::",
          listen_port: 8388,
          shadowsocks_method: "aes-256-gcm",
          server_password: "p",
        },
      });
    });
  });

  describe("jsonImportOutbound", () => {
    it("vless outbound", () => {
      ctx = ctx ?? buildSandbox();
      fnOut = fnOut ?? ctx.SbImpOutbound?.jsonImportOutbound;
      const got = fnOut({
        type: "vless",
        server: "a.b",
        server_port: 443,
        uuid: "uu",
        tls: { enabled: true, server_name: "a.b" },
      });
      expect(got).toEqual({
        ok: true,
        errors: [],
        fields: {
          type: "vless",
          server: "a.b",
          server_port: 443,
          server_uuid: "uu",
          tls_enabled: "1",
          tls_server_name: "a.b",
        },
      });
    });

    it("inbound rejected as outbound", () => {
      ctx = ctx ?? buildSandbox();
      fnOut = fnOut ?? ctx.SbImpOutbound?.jsonImportOutbound;
      const got = fnOut({
        type: "shadowsocks",
        listen: "::",
        listen_port: 8388,
        method: "aes-256-gcm",
        password: "p",
      });
      expect(got).toEqual({
        ok: false,
        errors: [
          'Looks like an inbound (has "listen"). Use the inbound importer.',
        ],
        fields: {},
      });
    });

    it("outbound missing type rejected", () => {
      ctx = ctx ?? buildSandbox();
      fnOut = fnOut ?? ctx.SbImpOutbound?.jsonImportOutbound;
      const got = fnOut({ server: "a.b", server_port: 443 });
      expect(got).toEqual({
        ok: false,
        errors: ['Missing "type" field'],
        fields: {},
      });
    });

    it("outbound unknown type rejected", () => {
      ctx = ctx ?? buildSandbox();
      fnOut = fnOut ?? ctx.SbImpOutbound?.jsonImportOutbound;
      const got = fnOut({ type: "wireguard" });
      expect(got).toEqual({
        ok: false,
        errors: ["Unknown outbound type: wireguard"],
        fields: {},
      });
    });

    it("hysteria2 outbound with obfs", () => {
      ctx = ctx ?? buildSandbox();
      fnOut = fnOut ?? ctx.SbImpOutbound?.jsonImportOutbound;
      const got = fnOut({
        type: "hysteria2",
        server: "h.b",
        server_port: 8443,
        password: "pw",
        up_mbps: 100,
        down_mbps: 50,
        obfs: { type: "salamander", password: "op" },
      });
      expect(got).toEqual({
        ok: true,
        errors: [],
        fields: {
          type: "hysteria2",
          server: "h.b",
          server_port: 8443,
          server_password: "pw",
          up_mbps: "100",
          down_mbps: "50",
          obfs_type: "salamander",
          obfs_password: "op",
        },
      });
    });

    it("http transport multi-host routes to transport_hosts list", () => {
      ctx = ctx ?? buildSandbox();
      fnOut = fnOut ?? ctx.SbImpOutbound?.jsonImportOutbound;
      const got = fnOut({
        type: "vless",
        server: "a.b",
        server_port: 443,
        uuid: "u",
        transport: {
          type: "http",
          host: ["a.example", "b.example"],
          path: "/api",
        },
      });
      expect(got).toEqual({
        ok: true,
        errors: [],
        fields: {
          type: "vless",
          server: "a.b",
          server_port: 443,
          server_uuid: "u",
          transport_type: "http",
          transport_path: "/api",
          transport_hosts: ["a.example", "b.example"],
        },
      });
    });

    it("ws transport host stays scalar", () => {
      ctx = ctx ?? buildSandbox();
      fnOut = fnOut ?? ctx.SbImpOutbound?.jsonImportOutbound;
      const got = fnOut({
        type: "vless",
        server: "a.b",
        server_port: 443,
        uuid: "u",
        transport: { type: "ws", host: "cdn.example", path: "/ws" },
      });
      expect(got).toEqual({
        ok: true,
        errors: [],
        fields: {
          type: "vless",
          server: "a.b",
          server_port: 443,
          server_uuid: "u",
          transport_type: "ws",
          transport_path: "/ws",
          transport_host: "cdn.example",
        },
      });
    });

    it("outbound tls alpn stays array", () => {
      ctx = ctx ?? buildSandbox();
      fnOut = fnOut ?? ctx.SbImpOutbound?.jsonImportOutbound;
      const got = fnOut({
        type: "vless",
        server: "a.b",
        server_port: 443,
        uuid: "u",
        tls: { enabled: true, alpn: ["h2", "http/1.1"] },
      });
      expect(got).toEqual({
        ok: true,
        errors: [],
        fields: {
          type: "vless",
          server: "a.b",
          server_port: 443,
          server_uuid: "u",
          tls_enabled: "1",
          tls_alpn: ["h2", "http/1.1"],
        },
      });
    });

    it("outbound rejects bare direct type", () => {
      ctx = ctx ?? buildSandbox();
      fnOut = fnOut ?? ctx.SbImpOutbound?.jsonImportOutbound;
      const got = fnOut({ type: "direct", server: "x.y", server_port: 1 });
      expect(got).toEqual({
        ok: false,
        errors: ["Unknown outbound type: direct"],
        fields: {},
      });
    });

    it("outbound non-numeric server_port rejected", () => {
      ctx = ctx ?? buildSandbox();
      fnOut = fnOut ?? ctx.SbImpOutbound?.jsonImportOutbound;
      const got = fnOut({
        type: "vless",
        server: "a.b",
        server_port: "nope",
        uuid: "u",
      });
      expect(got).toEqual({
        ok: false,
        errors: ["Invalid port: nope"],
        fields: {},
      });
    });

    it("outbound bad up_mbps rejected", () => {
      ctx = ctx ?? buildSandbox();
      fnOut = fnOut ?? ctx.SbImpOutbound?.jsonImportOutbound;
      const got = fnOut({
        type: "hysteria2",
        server: "h.b",
        server_port: 8443,
        password: "pw",
        up_mbps: "fast",
      });
      expect(got).toEqual({
        ok: false,
        errors: ["Invalid up_mbps: fast"],
        fields: {},
      });
    });

    it("outbound bad alter_id rejected", () => {
      ctx = ctx ?? buildSandbox();
      fnOut = fnOut ?? ctx.SbImpOutbound?.jsonImportOutbound;
      const got = fnOut({
        type: "vmess",
        server: "a.b",
        server_port: 443,
        uuid: "u",
        alter_id: "x",
      });
      expect(got).toEqual({
        ok: false,
        errors: ["Invalid alter_id: x"],
        fields: {},
      });
    });
  });
});

// Merged from tests/cross/test_json_import_uii3_uio4.test.ts, which carried a
// byte-for-byte copy of buildSandbox() above (and a duplicate of the uii-1 case).
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
      expect(r.fields.transport_type).toBe("ws");
      expect(r.fields.transport_path).toBe("/p");
      expect(r.fields.transport_host).toBe("h.com");
      expect(r.fields.tls_enabled).toBe("1");
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
      expect(r.fields.tls_enabled).toBe("1");
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
      expect(r.fields.tls_enabled).toBe("1");
      expect(r.fields.reality_enabled).toBe("1");
      expect(r.fields.reality_public_key).toBe("PUBKEY");
      expect(r.fields.reality_short_id).toBe("ab12");
    });
  });
});
