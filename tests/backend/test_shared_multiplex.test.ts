import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode, runUcodeJSON } from "../helpers/ucode.ts";

// Port of tests/backend/test_shared_multiplex.sh
// Declarative emit_spec path via filler for the shared multiplex block.

describe("shared multiplex block", () => {
  useGuest();

  it("Test 1: disabled → no multiplex key", async () => {
    const src = `
      let f = require("builder._filler");
      let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ multiplex:true } },
        { ".name":"t", multiplex_enabled:"0" }
      );
      print(got.multiplex == null ? "NULL" : "PRESENT");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("NULL");
  });

  it("Test 2: enabled — default protocol smux", async () => {
    const src = `
      let f = require("builder._filler");
      let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ multiplex:true } },
        { ".name":"t", multiplex_enabled:"1" }
      );
      print(sprintf("%s|%s", got.multiplex.enabled, got.multiplex.protocol));
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("true|smux");
  });

  it("Test 3: full advanced multiplex", async () => {
    const src = `
      let f = require("builder._filler");
      let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ multiplex:true } },
        { ".name":"t", multiplex_enabled:"1", multiplex_protocol:"yamux",
          multiplex_max_connections:"4", multiplex_min_streams:"4",
          multiplex_max_streams:"8", multiplex_padding:"1" }
      );
      print(sprintf("%J", got));
    `;
    const got = await runUcodeJSON<Record<string, unknown>>(src);
    const mx = got.multiplex as Record<string, unknown>;
    expect(mx).toBeDefined();
    expect(mx.protocol).toBe("yamux");
    expect(mx.max_connections).toBe(4);
    expect(mx.min_streams).toBe(4);
    expect(mx.max_streams).toBe(8);
    expect(mx.padding).toBe(true);
  });
});
