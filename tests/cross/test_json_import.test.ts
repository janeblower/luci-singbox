import { describe, expect, it } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import vm from "node:vm";

// tests/cross/test_json_import.sh — drives the JSON-import parser in main.js
// through node. Skips when node is unavailable (node IS available in bun test context).

const REPO = resolve(import.meta.dir, "../..");
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

    it("tun with malformed address element does not throw (regression: non-string crashed import)", () => {
      ctx = ctx ?? buildSandbox();
      fn = fn ?? ctx.SbImpInbound?.jsonImportInbound;
      // Untrusted paste: numeric/null elements must not throw on .indexOf.
      const got = fn({
        type: "tun",
        tag: "tun0",
        interface_name: "tun0",
        address: [123, null, "10.0.0.1/24", "fd00::1/64"],
      });
      expect(got.ok).toBe(true);
      expect(got.fields.inet4_address).toBe("10.0.0.1/24");
      expect(got.fields.inet6_address).toBe("fd00::1/64");
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
          security: "reality",
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
          security: "tls",
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
          transport: "http",
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
          transport: "ws",
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
          security: "tls",
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
