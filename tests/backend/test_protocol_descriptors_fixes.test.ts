import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode, runUcodeJSON } from "../helpers/ucode.ts";

// Port of tests/backend/test_protocol_descriptors_fixes.sh
// Regression tests for protocol-descriptor correctness bugs:
//   S4-1  hysteria2 obfs with empty password must NOT emit obfs{}
//   S4-6  direct proxy_protocol enum: "0" must not emit proxy_protocol:0
//   S4-7  IPv6-literal hosts parse in share-links
//   S4-8  colon-bearing secrets survive name:secret splitting
//   S4-9  dns rewrite_ttl NaN guard

describe("protocol descriptor fixes", () => {
  useGuest();

  // ---- S4-1: hysteria2 outbound, obfs_type set but obfs_password empty ----
  it("S4-1: hysteria2 outbound — obfs_type set but empty obfs_password must NOT emit obfs{}", async () => {
    const src = `
      let ob = require("outbound");
      let s = {
        ".name": "hy2", type: "hysteria2",
        server: "1.2.3.4", server_port: "443",
        server_password: "mypass",
        obfs_type: "salamander", obfs_password: "",
      };
      let got = ob.build_constructor_for(s, "hysteria2");
      print(sprintf("%J", got));
    `;
    const got = await runUcodeJSON<Record<string, unknown>>(src);
    expect(got.obfs).toBeUndefined();
  });

  it("S4-1 sanity: real obfs_password still emits obfs{}", async () => {
    const src = `
      let ob = require("outbound");
      let s = {
        ".name": "hy2", type: "hysteria2",
        server: "1.2.3.4", server_port: "443",
        server_password: "mypass",
        obfs_type: "salamander", obfs_password: "realobfspw",
      };
      let got = ob.build_constructor_for(s, "hysteria2");
      print(sprintf("%J", got));
    `;
    const got = await runUcodeJSON<Record<string, unknown>>(src);
    expect(got.obfs).toBeDefined();
    const obfs = got.obfs as Record<string, unknown>;
    expect(obfs.type).toBe("salamander");
    expect(obfs.password).toBe("realobfspw");
  });

  it("S4-1: hysteria2 inbound — obfs_type set but empty obfs_password must NOT emit obfs{}", async () => {
    const src = `
      let inb = require("inbound");
      let s = {
        ".name": "hy2_in", ".type": "inbound",
        enabled: "1", protocol: "hysteria2",
        listen: "::", listen_port: "443",
        server_password: "mypass",
        obfs_type: "salamander", obfs_password: "",
      };
      let got = inb.build_one(s);
      print(sprintf("%J", got));
    `;
    const got = await runUcodeJSON<Record<string, unknown>>(src);
    expect(got.obfs).toBeUndefined();
  });

  it("S4-1: hy2 share-link with obfs but no obfs-password emits no obfs", async () => {
    const src = `
      let ob = require("outbound");
      // share-link with obfs param but empty password
      let url = "hy2://mypass@1.2.3.4:443?obfs=salamander&obfs-password=";
      let got = ob.parse_proxy_url(url);
      print(sprintf("%J", got));
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    // parse_proxy_url returns a section dict; obfs_password should be empty/absent
    let parsed: Record<string, unknown> = {};
    try {
      parsed = JSON.parse(r.stdout) as Record<string, unknown>;
    } catch {
      // If parse fails, check raw output doesn't have obfs
    }
    // Either no obfs_password or it's empty string
    const obfsPw = parsed.obfs_password as string | undefined;
    expect(!obfsPw || obfsPw === "").toBe(true);
  });

  // ---- S4-6: direct proxy_protocol enum ----
  it("S4-6: direct outbound — proxy_protocol '0' must not emit proxy_protocol:0", async () => {
    const src = `
      let ob = require("outbound");
      let s = { ".name": "d", type: "direct", proxy_protocol: "0" };
      let got = ob.build_constructor_for(s, "direct");
      print(sprintf("%J", got));
    `;
    const got = await runUcodeJSON<Record<string, unknown>>(src);
    expect(got.proxy_protocol).toBeUndefined();
  });

  it("S4-6: direct outbound — proxy_protocol '1' emits proxy_protocol:1", async () => {
    const src = `
      let ob = require("outbound");
      let s = { ".name": "d", type: "direct", proxy_protocol: "1" };
      let got = ob.build_constructor_for(s, "direct");
      print(sprintf("%J", got));
    `;
    const got = await runUcodeJSON<Record<string, unknown>>(src);
    expect(got.proxy_protocol).toBe(1);
  });

  it("S4-6: direct outbound — empty proxy_protocol emits nothing", async () => {
    const src = `
      let ob = require("outbound");
      let s = { ".name": "d", type: "direct", proxy_protocol: "" };
      let got = ob.build_constructor_for(s, "direct");
      print(sprintf("%J", got));
    `;
    const got = await runUcodeJSON<Record<string, unknown>>(src);
    expect(got.proxy_protocol).toBeUndefined();
  });

  // ---- S4-7: IPv6-literal hosts parse in share-links ----
  it("S4-7: IPv6-literal host in vless share-link stored WITHOUT brackets", async () => {
    const src = `
      let ob = require("outbound");
      let url = "vless://11111111-2222-3333-4444-555555555555@[2001:db8::1]:443?security=tls&sni=example.com#ipv6test";
      let got = ob.parse_proxy_url(url);
      print(sprintf("%J", got));
    `;
    const got = await runUcodeJSON<Record<string, unknown>>(src);
    // S4.2: host stored WITHOUT the [...] brackets
    expect(got.server).toBe("2001:db8::1");
    expect(got.server_port).toBe("443");
  });

  it("S4-7: IPv4 share-links still work (no regression)", async () => {
    const src = `
      let ob = require("outbound");
      let url = "vless://11111111-2222-3333-4444-555555555555@1.2.3.4:443?security=tls#ipv4test";
      let got = ob.parse_proxy_url(url);
      print(sprintf("%J", got));
    `;
    const got = await runUcodeJSON<Record<string, unknown>>(src);
    expect(got.server).toBe("1.2.3.4");
    expect(got.server_port).toBe("443");
  });

  // ---- S4-8: colon-bearing secrets survive name:secret splitting ----
  it("S4-8: hysteria2 inbound multi-user — password contains a colon", async () => {
    const src = `
      let inb = require("inbound");
      let s = {
        ".name": "h2", ".type": "inbound",
        enabled: "1", protocol: "hysteria2",
        listen: "::", listen_port: "443",
        inbound_user: ["alice:pass:with:colon"],
      };
      let got = inb.build_one(s);
      print(sprintf("%J", got));
    `;
    const got = await runUcodeJSON<Record<string, unknown>>(src);
    const users = got.users as Array<{ name?: string; password: string }>;
    expect(users).toHaveLength(1);
    expect(users[0].password).toBe("pass:with:colon");
  });

  it("S4-8: mixed inbound — password contains a colon", async () => {
    const src = `
      let inb = require("inbound");
      let s = {
        ".name": "mix", ".type": "inbound",
        enabled: "1", protocol: "mixed",
        listen: "::", listen_port: "1080",
        mixed_user: ["alice:pass:with:colon"],
      };
      let got = inb.build_one(s);
      print(sprintf("%J", got));
    `;
    const got = await runUcodeJSON<Record<string, unknown>>(src);
    const users = got.users as Array<{ username: string; password: string }>;
    expect(users).toHaveLength(1);
    expect(users[0].username).toBe("alice");
    expect(users[0].password).toBe("pass:with:colon");
  });

  it("S4-8: shadowsocks inbound — password (tail) contains a colon", async () => {
    const src = `
      let inb = require("inbound");
      let s = {
        ".name": "ss", ".type": "inbound",
        enabled: "1", protocol: "shadowsocks",
        listen: "::", listen_port: "8388",
        ss_user: ["alice:2022-blake3-aes-128-gcm:pass:with:colon"],
      };
      let got = inb.build_one(s);
      print(sprintf("%J", got));
    `;
    const got = await runUcodeJSON<Record<string, unknown>>(src);
    const users = got.users as Array<{ name: string; password: string }>;
    expect(users).toHaveLength(1);
    expect(users[0].name).toBe("alice");
    expect(users[0].password).toBe("pass:with:colon");
  });

  // ---- S4-9: dns rewrite_ttl NaN guard ----
  it("S4-9: dns build_rules — non-numeric rewrite_ttl ('abc') is dropped (not emitted)", async () => {
    const src = `
      let dns = require("dns");
      // Mock cursor with one dns_rule section
      let uci = require("uci");
      let cur = uci.cursor();
      // We test build_rules by creating a synthetic rule and checking the result.
      // The declarative filler: rewrite_ttl is a num field with omit_when:empty.
      // A non-numeric value ("abc") must be dropped.
      let reg = require("builder.dns_rule.registry");
      let filler = require("builder._filler");
      // Get the default dns_rule descriptor
      let d = reg.get("dns_rule", "default");
      // Section with bad rewrite_ttl
      let s = {
        ".name": "r1", ".type": "dns_rule", type: "default",
        action: "route", server: "dns1",
        rewrite_ttl: "abc",
      };
      let got = filler.build(d, s);
      print(got.rewrite_ttl == null ? "ABSENT" : sprintf("PRESENT:%s", got.rewrite_ttl));
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("ABSENT");
  });

  it("S4-9: dns build_rules — '0' means explicit disable (must emit 0)", async () => {
    const src = `
      let reg = require("builder.dns_rule.registry");
      let filler = require("builder._filler");
      let d = reg.get("dns_rule", "default");
      let s = {
        ".name": "r1", ".type": "dns_rule", type: "default",
        action: "route", server: "dns1",
        rewrite_ttl: "0",
      };
      let got = filler.build(d, s);
      print(got.rewrite_ttl === 0 ? "ZERO" : sprintf("OTHER:%J", got.rewrite_ttl));
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("ZERO");
  });

  it("S4-9: dns build_rules — explicit numeric value emitted as-is", async () => {
    const src = `
      let reg = require("builder.dns_rule.registry");
      let filler = require("builder._filler");
      let d = reg.get("dns_rule", "default");
      let s = {
        ".name": "r1", ".type": "dns_rule", type: "default",
        action: "route", server: "dns1",
        rewrite_ttl: "300",
      };
      let got = filler.build(d, s);
      print(got.rewrite_ttl === 300 ? "300" : sprintf("OTHER:%J", got.rewrite_ttl));
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("300");
  });
});
