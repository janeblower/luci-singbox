import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

// Port of tests/backend/test_shared_tls.sh
// Declarative emit_spec path via filler for the shared TLS block.
// Covers: disabled (null), minimal enabled, Reality client, ECH, TLS fragment,
// uTLS, hysteria2 force-enabled.

describe("shared TLS block", () => {
  useGuest();

  it("Test 1: tls_enabled=0 → no tls key in result (block gated out)", async () => {
    const src = `
      let f = require("builder._filler");
      let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ tls:{} } },
        { ".name":"t", tls_enabled:"0" }
      );
      print(got.tls == null ? "NULL" : "NOTNULL");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("NULL");
  });

  it("Test 2: tls_enabled=1 + tls_server_name → enabled+server_name", async () => {
    const src = `
      let f = require("builder._filler");
      let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ tls:{} } },
        { ".name":"t", tls_enabled:"1", tls_server_name:"ex.com" }
      );
      print(sprintf("%s|%s", got.tls.enabled, got.tls.server_name));
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("true|ex.com");
  });

  it("Test 2b: alpn arrives as a JSON array (guard against as_array() regressions)", async () => {
    const src = `
      let f = require("builder._filler");
      let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ tls:{} } },
        { ".name":"t", tls_enabled:"1", tls_alpn:["h2","http/1.1"] }
      );
      print(sprintf("%s|%d|%s", type(got.tls.alpn), length(got.tls.alpn), got.tls.alpn[0]));
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("array|2|h2");
  });

  it("Test 3: Reality client — enabled, public_key, short_id", async () => {
    const src = `
      let f = require("builder._filler");
      let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ tls:{} } },
        { ".name":"t", tls_enabled:"1", reality_enabled:"1",
          reality_public_key:"pk", reality_short_id:"00ff" }
      );
      print(sprintf("%s|%s|%s", got.tls.reality.enabled, got.tls.reality.public_key, got.tls.reality.short_id));
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("true|pk|00ff");
  });

  it("Regression guard: tls.reality.short_id must be a string, not an array (Phase B fix)", async () => {
    const src = `
      let f = require("builder._filler");
      let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ tls:{} } },
        { ".name":"t", tls_enabled:"1", reality_enabled:"1",
          reality_public_key:"pk", reality_short_id:"00ff" }
      );
      print(type(got.tls.reality.short_id));
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("string");
  });

  it("Test 3b: inbound Reality — private_key + handshake server", async () => {
    const src = `
      let f = require("builder._filler");
      let got = f.build(
        { kind:"inbound", sing_box_type:"trojan", fields:[], shared:{ tls:{} } },
        { ".name":"t", listen_port:"443", tls_enabled:"1", reality_enabled:"1",
          reality_private_key:"pkv", reality_short_id:"00ff",
          reality_handshake_server:"h.example", reality_handshake_server_port:"443" }
      );
      print(sprintf("%s|%s|%s|%d",
        got.tls.reality.enabled, got.tls.reality.private_key,
        got.tls.reality.handshake.server, got.tls.reality.handshake.server_port));
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("true|pkv|h.example|443");
  });

  it("Test 4: uTLS client — enabled + fingerprint", async () => {
    const src = `
      let f = require("builder._filler");
      let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ tls:{} } },
        { ".name":"t", tls_enabled:"1", utls_enabled:"1", utls_fingerprint:"firefox" }
      );
      print(sprintf("%s|%s", got.tls.utls.enabled, got.tls.utls.fingerprint));
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("true|firefox");
  });

  it("Test 5: hysteria2 force-enabled (tls_enabled=0 ignored)", async () => {
    const src = `
      let f = require("builder._filler");
      let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ tls:{ force_enabled:true } } },
        { ".name":"t", tls_enabled:"0" }
      );
      print(got.tls == null ? "NULL" : sprintf("%s", got.tls.enabled));
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("true");
  });

  it("Test 6: TLS fragment — fragment bool + fallback_delay", async () => {
    const src = `
      let f = require("builder._filler");
      let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ tls:{} } },
        { ".name":"t", tls_enabled:"1", tls_fragment:"1",
          tls_fragment_fallback_delay:"500ms" }
      );
      print(sprintf("%s|%s", got.tls.fragment, got.tls.fragment_fallback_delay));
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("true|500ms");
  });

  it("Test 7: server-side ECH (key path, not config path)", async () => {
    const src = `
      let f = require("builder._filler");
      let got = f.build(
        { kind:"inbound", sing_box_type:"trojan", fields:[], shared:{ tls:{} } },
        { ".name":"t", listen_port:"443", tls_enabled:"1", tls_ech_enabled:"1",
          tls_ech_key_path:"/etc/sb/ech.key" }
      );
      print(sprintf("%s|%s", got.tls.ech.enabled, got.tls.ech.key_path));
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("true|/etc/sb/ech.key");
  });

  it("Test 8: fields[] includes tls_enabled gate and reality_enabled sub-toggle", async () => {
    const src = `
      let tls = require("builder._shared.tls");
      let names = "";
      for (let f in tls.fields) names += f.name + ",";
      print(names);
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("tls_enabled,");
    expect(r.stdout).toContain("reality_enabled,");
  });

  it("Test 9: tls_alpn and tls_cipher_suites carry combobox suggestions (values[])", async () => {
    const src = `
      let tls = require("builder._shared.tls");
      let alpn = null, cs = null;
      for (let f in tls.fields) {
        if (f.name == "tls_alpn")          alpn = f;
        if (f.name == "tls_cipher_suites") cs   = f;
      }
      print(sprintf("%s|%d|%s|%s|%s|%d",
        alpn.type, length(alpn.values), alpn.values[0], alpn.values[2],
        cs.type, length(cs.values)));
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    // alpn: list type, 3 suggestions (h2, http/1.1, h3), index 0=h2, index 2=h3
    // cs: list type, at least 1 suggestion
    const [alpnType, alpnCount, alpn0, alpn2, csType, csCountStr] = r.stdout
      .trim()
      .split("|");
    expect(alpnType).toBe("list");
    expect(Number(alpnCount)).toBe(3);
    expect(alpn0).toBe("h2");
    expect(alpn2).toBe("h3");
    expect(csType).toBe("list");
    expect(Number(csCountStr)).toBeGreaterThanOrEqual(1);
  });
});
