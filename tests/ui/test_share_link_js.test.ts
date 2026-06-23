import { describe, expect, it } from "bun:test";
import { resolve } from "node:path";
import { loadLuciModule } from "../helpers/luci.ts";

// tests/test_share_link_js.sh — exercises importers/outbound.shareLinkImport
// from Node so the JS-side share-link parsing has regression coverage.

const OUTBOUND_JS = resolve(
  import.meta.dir,
  "../../luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/importers/outbound.js",
);

const { exports: mod } = loadLuciModule(OUTBOUND_JS, {
  _: (s: unknown) => s,
  Object,
  Array,
  String,
  JSON,
  Promise,
  parseInt,
  decodeURIComponent,
  encodeURIComponent,
  Buffer,
  atob: (s: string) => Buffer.from(s, "base64").toString("utf8"),
  btoa: (s: string) => Buffer.from(s, "utf8").toString("base64"),
});

describe("shareLinkImport (importers/outbound.js)", () => {
  // Test 1: vless URL
  it("vless type", () => {
    const r = mod.shareLinkImport(
      "vless://11111111-2222-3333-4444-555555555555@example.com:443?type=tcp#vlsrv",
    );
    expect(r.ok && r.fields.type).toBe("vless");
  });
  it("vless server", () => {
    const r = mod.shareLinkImport(
      "vless://11111111-2222-3333-4444-555555555555@example.com:443?type=tcp#vlsrv",
    );
    expect(r.fields.server).toBe("example.com");
  });
  it("vless port", () => {
    const r = mod.shareLinkImport(
      "vless://11111111-2222-3333-4444-555555555555@example.com:443?type=tcp#vlsrv",
    );
    expect(r.fields.server_port).toBe(443);
  });
  it("vless uuid", () => {
    const r = mod.shareLinkImport(
      "vless://11111111-2222-3333-4444-555555555555@example.com:443?type=tcp#vlsrv",
    );
    expect(r.fields.server_uuid).toBe("11111111-2222-3333-4444-555555555555");
  });

  // Test 2: hysteria2 with obfs — MUST set obfs_type / obfs_password (NOT hysteria2_obfs_*)
  it("hy2 type", () => {
    const r = mod.shareLinkImport(
      "hysteria2://pw@h.example:443?obfs=salamander&obfs-password=op#hy2",
    );
    expect(r.ok && r.fields.type).toBe("hysteria2");
  });
  it("hy2 password", () => {
    const r = mod.shareLinkImport(
      "hysteria2://pw@h.example:443?obfs=salamander&obfs-password=op#hy2",
    );
    expect(r.fields.server_password).toBe("pw");
  });
  it("hy2 obfs_type key (not hysteria2_obfs_type)", () => {
    const r = mod.shareLinkImport(
      "hysteria2://pw@h.example:443?obfs=salamander&obfs-password=op#hy2",
    );
    expect(r.fields.obfs_type).toBe("salamander");
  });
  it("hy2 obfs_password key (not hysteria2_obfs_password)", () => {
    const r = mod.shareLinkImport(
      "hysteria2://pw@h.example:443?obfs=salamander&obfs-password=op#hy2",
    );
    expect(r.fields.obfs_password).toBe("op");
  });
  it("hy2 no legacy hysteria2_obfs_type key", () => {
    const r = mod.shareLinkImport(
      "hysteria2://pw@h.example:443?obfs=salamander&obfs-password=op#hy2",
    );
    expect("hysteria2_obfs_type" in r.fields).toBe(false);
  });

  // Test 3: SS base64 SIP002 fallback
  it("ss SIP002 method", () => {
    const b64 = Buffer.from("aes-256-gcm:secret", "utf8").toString("base64");
    const r = mod.shareLinkImport(`ss://${b64}@ss.example:8388#ss`);
    expect(r.fields.shadowsocks_method).toBe("aes-256-gcm");
  });
  it("ss SIP002 password", () => {
    const b64 = Buffer.from("aes-256-gcm:secret", "utf8").toString("base64");
    const r = mod.shareLinkImport(`ss://${b64}@ss.example:8388#ss`);
    expect(r.fields.server_password).toBe("secret");
  });

  // Test 4: trojan
  it("trojan type and password", () => {
    const r = mod.shareLinkImport("trojan://tjpw@trojan.example:443#tj");
    expect(
      r.fields.type === "trojan" && r.fields.server_password === "tjpw",
    ).toBe(true);
  });

  // Test 5: SS plain form (modern method:password)
  it("ss plain method", () => {
    const r = mod.shareLinkImport(
      "ss://aes-128-gcm:mypass@ss2.example:8388#ss2",
    );
    expect(r.fields.shadowsocks_method).toBe("aes-128-gcm");
  });
  it("ss plain password", () => {
    const r = mod.shareLinkImport(
      "ss://aes-128-gcm:mypass@ss2.example:8388#ss2",
    );
    expect(r.fields.server_password).toBe("mypass");
  });

  // Test 6: malformed %-encoding must NOT throw (spec S2-10)
  it("malformed % does not throw", () => {
    let threw = false;
    try {
      mod.shareLinkImport("vless://uuid@example.com:443?path=%zz#%E0%A4%A");
    } catch {
      threw = true;
    }
    expect(threw).toBe(false);
  });
  it("malformed % still parses core fields", () => {
    const r = mod.shareLinkImport(
      "vless://uuid@example.com:443?path=%zz#%E0%A4%A",
    );
    expect(r?.ok && r.fields.server).toBe("example.com");
  });

  // Test 7: totally broken %-only userinfo is tolerated
  it("malformed trojan userinfo does not throw", () => {
    let threw = false;
    try {
      mod.shareLinkImport("trojan://%zz%yy@trojan.example:443#bad");
    } catch {
      threw = true;
    }
    expect(threw).toBe(false);
  });
  it("malformed trojan userinfo yields a result object", () => {
    const r = mod.shareLinkImport("trojan://%zz%yy@trojan.example:443#bad");
    expect(r && typeof r.ok).toBe("boolean");
  });

  // Test 8: bracketed IPv6 literal hosts (S4-7)
  it("vless IPv6 host", () => {
    const r = mod.shareLinkImport(
      "vless://11111111-2222-3333-4444-555555555555@[2001:db8::1]:443?type=tcp#v6",
    );
    expect(
      r.ok &&
        r.fields.server === "[2001:db8::1]" &&
        r.fields.server_port === 443,
    ).toBe(true);
  });
  it("trojan IPv6 host", () => {
    const r = mod.shareLinkImport("trojan://pw@[2001:db8::2]:8443#v6");
    expect(
      r.ok &&
        r.fields.server === "[2001:db8::2]" &&
        r.fields.server_port === 8443,
    ).toBe(true);
  });
  it("hy2 IPv6 host", () => {
    const r = mod.shareLinkImport("hysteria2://pw@[2001:db8::3]:443#v6");
    expect(
      r.ok &&
        r.fields.server === "[2001:db8::3]" &&
        r.fields.server_port === 443,
    ).toBe(true);
  });
  it("ss IPv6 host", () => {
    const r = mod.shareLinkImport("ss://aes-256-gcm:pw@[2001:db8::4]:8388#v6");
    expect(
      r.ok &&
        r.fields.server === "[2001:db8::4]" &&
        r.fields.server_port === 8388,
    ).toBe(true);
  });
  it("trojan IPv4 still parses (no regression)", () => {
    const r = mod.shareLinkImport("trojan://pw@1.2.3.4:443#v4");
    expect(
      r.ok && r.fields.server === "1.2.3.4" && r.fields.server_port === 443,
    ).toBe(true);
  });

  it("trojan query: sni/transport/path/insecure pre-filled (regression: query was dropped)", () => {
    const r = mod.shareLinkImport(
      "trojan://pw@trojan.example:443?sni=cdn.example&type=ws&path=%2Fws&allowInsecure=1#tj",
    );
    expect(r.ok).toBe(true);
    expect(r.fields.tls_server_name).toBe("cdn.example");
    expect(r.fields.transport).toBe("ws");
    expect(r.fields.transport_path).toBe("/ws");
    expect(r.fields.tls_insecure).toBe("1");
  });
});
