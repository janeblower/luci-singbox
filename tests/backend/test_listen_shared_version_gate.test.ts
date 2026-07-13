import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

// _filler._build_block's _version_gate_seq drops a shared-block emit_spec
// entry whose min_version the probed core doesn't meet, BEFORE _emit_scalar
// ever sees it. This is scoped to shared blocks only (see the comment above
// _version_gate_seq in _filler.uc) — the listen block is the first shared
// block to actually need it, because its 1.12/1.13 fields are unknown-field
// FATAL on an older sing-box (the whole config gets rejected), unlike e.g.
// tls.uc's kTLS fields, which stay UI-hint-only on purpose.
//
// tests/parity/corpus.uc's mixed_in_listen_shared fixture only exercises the
// "blocked" half of this (the guest's real installed core is 1.12, so the
// 1.13 trio is silently absent from that golden). This test pins
// SINGBOX_CORE_VERSION explicitly and checks BOTH directions: blocked below
// min_version, present at/above it.

const SRC = `
  let filler = require("builder._filler");
  let d = { kind:"inbound", sing_box_type:"mixed", shared:{ listen:true } };
  let s = { [".name"]:"m1", listen_port:"1080",
            tcp_fast_open:"1", bind_interface:"eth0", routing_mark:"1234",
            reuse_addr:"1", netns:"/var/run/netns/x",
            tcp_keep_alive:"5m", tcp_keep_alive_interval:"75s",
            disable_tcp_keep_alive:"1" };
  let o = filler.build(d, s);
  print(sprintf("%J\\n", o));
`;

async function build(core: string) {
  const r = await runUcode(SRC, [], [], { SINGBOX_CORE_VERSION: core });
  expect(r.exitCode).toBe(0);
  return JSON.parse(r.stdout.trim());
}

describe("listen shared block: emission-time version gate", () => {
  useGuest();

  it("below 1.12: the whole min_version-gated set is suppressed, ungated fields survive", async () => {
    const o = await build("1.11.0");
    expect(o.tcp_fast_open).toBe(true); // no min_version — always emits
    expect(o.bind_interface).toBeUndefined();
    expect(o.routing_mark).toBeUndefined();
    expect(o.reuse_addr).toBeUndefined();
    expect(o.netns).toBeUndefined();
    expect(o.tcp_keep_alive).toBeUndefined();
    expect(o.tcp_keep_alive_interval).toBeUndefined();
    expect(o.disable_tcp_keep_alive).toBeUndefined();
  });

  it("at 1.12: the 1.12 set emits, the 1.13 set (tcp_keep_alive*) stays gated", async () => {
    const o = await build("1.12.0");
    expect(o.bind_interface).toBe("eth0");
    expect(o.routing_mark).toBe(1234);
    expect(o.reuse_addr).toBe(true);
    expect(o.netns).toBe("/var/run/netns/x");
    expect(o.tcp_keep_alive).toBeUndefined();
    expect(o.tcp_keep_alive_interval).toBeUndefined();
    expect(o.disable_tcp_keep_alive).toBeUndefined();
  });

  it("at 1.13: every gated field emits", async () => {
    const o = await build("1.13.0");
    expect(o.bind_interface).toBe("eth0");
    expect(o.routing_mark).toBe(1234);
    expect(o.reuse_addr).toBe(true);
    expect(o.netns).toBe("/var/run/netns/x");
    expect(o.tcp_keep_alive).toBe("5m");
    expect(o.tcp_keep_alive_interval).toBe("75s");
    expect(o.disable_tcp_keep_alive).toBe(true);
  });
});
