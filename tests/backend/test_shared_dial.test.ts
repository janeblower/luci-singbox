import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode, runUcodeJSON } from "../helpers/ucode.ts";

// Port of tests/backend/test_shared_dial.sh
// Declarative emit_spec path via filler for the shared dial block.
// Dial uses merge mode: its keys fold directly into the outbound object
// (no got.dial sub-key).

describe("shared dial block", () => {
  useGuest();

  // Helper driver: build an outbound via filler with dial shared block.
  // Returns the full built object; dial fields are top-level (merge mode).
  function buildWithDial(section: Record<string, unknown>) {
    const sJson = JSON.stringify(section);
    return `
      let f = require("builder._filler");
      let s = ${sJson};
      s[".name"] = s[".name"] ?? "t";
      let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ dial:{} } },
        s
      );
      print(sprintf("%J", got));
    `;
  }

  it("Test 1: no fields set → merged object adds nothing (only type+tag present)", async () => {
    const src = buildWithDial({ ".name": "t" });
    const got = await runUcodeJSON<Record<string, unknown>>(src);
    const keys = Object.keys(got);
    expect(keys).toContain("type");
    expect(keys).toContain("tag");
    // dial is merge-mode; no dial-specific keys should appear
    expect(got.detour).toBeUndefined();
    expect(got.bind_interface).toBeUndefined();
  });

  it("Test 2: bind_interface only folds into top-level", async () => {
    const src = buildWithDial({ ".name": "t", bind_interface: "eth0" });
    const got = await runUcodeJSON<Record<string, unknown>>(src);
    expect(got.bind_interface).toBe("eth0");
    // no nested dial sub-key
    expect(got.dial).toBeUndefined();
  });

  it("Test 3: advanced — routing_mark + connect_timeout + udp_fragment", async () => {
    const src = `
      let f = require("builder._filler");
      let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ dial:{} } },
        { ".name":"t", routing_mark:"255", connect_timeout:"10s", udp_fragment:"1" }
      );
      print(sprintf("%s|%s|%s", got.routing_mark, got.connect_timeout, got.udp_fragment));
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    const parts = r.stdout.trim().split("|");
    expect(parts[0]).toBe("255");
    expect(parts[1]).toBe("10s");
    expect(parts[2]).toBe("true");
  });

  it("Test 4: every remaining field — detour, netns, network_strategy, fallback_delay, reuse_addr, tcp_fast_open, tcp_multi_path, inet4/inet6_bind_address", async () => {
    const src = `
      let f = require("builder._filler");
      let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ dial:{} } },
        { ".name":"t",
          detour: "proxy-out",
          network_strategy: "prefer_ipv4",
          fallback_delay: "300ms",
          reuse_addr: "1",
          tcp_fast_open: "1",
          tcp_multi_path: "1",
          inet4_bind_address: "0.0.0.0",
          inet6_bind_address: "::" }
      );
      print(sprintf("%J", got));
    `;
    const got = await runUcodeJSON<Record<string, unknown>>(src);
    expect(got.detour).toBe("proxy-out");
    expect(got.network_strategy).toBe("prefer_ipv4");
    expect(got.fallback_delay).toBe("300ms");
    expect(got.reuse_addr).toBe(true);
    expect(got.tcp_fast_open).toBe(true);
    expect(got.tcp_multi_path).toBe(true);
    expect(got.inet4_bind_address).toBe("0.0.0.0");
    expect(got.inet6_bind_address).toBe("::");
  });

  it("Test 5: detour and bind_interface carry dynamic selector sources", async () => {
    const src = `
      let d = require("builder._shared.dial");
      let dyn = {};
      for (let f in d.fields) if (f.dynamic) dyn[f.name] = f.dynamic;
      print(sprintf("%s|%s", dyn.detour, dyn.bind_interface));
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("outbounds|interfaces");
  });
});
