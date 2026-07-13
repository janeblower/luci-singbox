import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

// _filler._emit_scalar drops any entry — own field, group member or shared-block
// emit_spec entry — whose declared min_version the probed core doesn't meet. An
// unknown key is not ignored: sing-box refuses the WHOLE config, so a 1.13 key on
// a 1.12 core means the service does not start at all.
//
// Version gating is tested HERE, with the core pinned per case, and nowhere else:
// the parity lane pins SINGBOX_CORE_VERSION=99.0 precisely so its goldens assert
// what a descriptor emits with every field present, instead of silently reshaping
// themselves around whatever core the guest happens to install.

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

// The other half of the gate: _unfiller must skip exactly what _filler skips.
// A 1.13 key on a 1.12 core is NOT "known" (or the JSON editor's diff-apply — the
// rule is "known but absent from the JSON => delete from UCI" — would wipe a value
// set on a newer core: silent data loss), and is NOT consumed by parse() either,
// so it survives in `extra` -> json_extra -> re-emitted verbatim.
const UNFILL_SRC = `
  let unf = require("builder._unfiller");
  let d = { kind:"inbound", sing_box_type:"mixed", shared:{ listen:true } };
  let r = unf.parse(d, { type:"mixed", tag:"m1", listen:"::", listen_port:1080,
                         tcp_fast_open:true, tcp_keep_alive:"5m" });
  // Presence as an explicit bool: sprintf("%J") renders an absent key as null,
  // which would make "did the walk claim it?" indistinguishable from a null value.
  print(sprintf("%J\\n", {
    known_gated:   r.known.tcp_keep_alive  != null,
    known_ungated: r.known.tcp_fast_open   != null,
    field_gated:   r.fields.tcp_keep_alive != null,
    extra_gated:   r.extra.tcp_keep_alive,
  }));
`;

async function build(core: string) {
  const r = await runUcode(SRC, [], [], { SINGBOX_CORE_VERSION: core });
  expect(r.exitCode).toBe(0);
  return JSON.parse(r.stdout.trim());
}

async function unfill(core: string) {
  const r = await runUcode(UNFILL_SRC, [], [], { SINGBOX_CORE_VERSION: core });
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

// The gate is not decoration: on a 1.12 core these keys make sing-box refuse the
// WHOLE config ("json: unknown field") and the daemon never starts. Assert their
// ABSENCE through the real descriptors — delete the min_version from
// _shared/quic.uc or _shared/tls.uc's emit_spec entries and these go red, which
// is the whole point (the parity lane pins 99.0 and cannot notice).
const QUIC_SRC = `
  require("builder.protocols.tuic");
  let reg = require("builder.protocols.registry");
  let filler = require("builder._filler");
  let s = { [".name"]:"t1", server:"e.com", server_port:"443",
            server_uuid:"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", server_password:"p",
            quic_initial_packet_size:"1200", quic_disable_path_mtu_discovery:"1" };
  print(sprintf("%J\\n", filler.build(reg.get("outbound","tuic"), s)));
`;

const KTLS_SRC = `
  require("builder.protocols.trojan");
  let reg = require("builder.protocols.registry");
  let filler = require("builder._filler");
  let s = { [".name"]:"tr1", server:"e.com", server_port:"443", server_password:"p",
            tls_enabled:"1", tls_server_name:"e.com",
            tls_kernel_tx:"1", tls_kernel_rx:"1" };
  print(sprintf("%J\\n", filler.build(reg.get("outbound","trojan"), s)));
`;

async function buildSrc(src: string, core: string) {
  const r = await runUcode(src, [], [], { SINGBOX_CORE_VERSION: core });
  expect(r.exitCode).toBe(0);
  return JSON.parse(r.stdout.trim());
}

describe("quic + tls shared blocks: the same gate, on a real 1.12 core", () => {
  useGuest();

  it("quic (1.14 keys) are NOT emitted on 1.12 — tuic outbound", async () => {
    const o = await buildSrc(QUIC_SRC, "1.12.0");
    expect(o.initial_packet_size).toBeUndefined();
    expect(o.disable_path_mtu_discovery).toBeUndefined();
    expect(o.type).toBe("tuic"); // the rest of the descriptor still built
  });

  it("quic (1.14 keys) ARE emitted on 1.14", async () => {
    const o = await buildSrc(QUIC_SRC, "1.14.0");
    expect(o.initial_packet_size).toBe(1200);
    expect(o.disable_path_mtu_discovery).toBe(true);
  });

  it("kTLS (1.13 keys) are NOT emitted on 1.12 — trojan outbound", async () => {
    const o = await buildSrc(KTLS_SRC, "1.12.0");
    expect(o.tls.enabled).toBe(true); // the TLS block itself still emits
    expect(o.tls.kernel_tx).toBeUndefined();
    expect(o.tls.kernel_rx).toBeUndefined();
  });

  it("kTLS (1.13 keys) ARE emitted on 1.13", async () => {
    const o = await buildSrc(KTLS_SRC, "1.13.0");
    expect(o.tls.kernel_tx).toBe(true);
    expect(o.tls.kernel_rx).toBe(true);
  });
});

describe("listen shared block: _unfiller gates `known` the same way", () => {
  useGuest();

  it("at 1.12: a 1.13 key is neither known nor consumed — it survives in extra", async () => {
    const r = await unfill("1.12.0");
    expect(r.known_gated).toBe(false); // NOT known => diff-apply can't delete it
    expect(r.known_ungated).toBe(true); // ungated siblings are unaffected
    expect(r.field_gated).toBe(false);
    expect(r.extra_gated).toBe("5m"); // -> json_extra -> re-emitted verbatim
  });

  it("at 1.13: the same key is known, consumed into a field, and not extra", async () => {
    const r = await unfill("1.13.0");
    expect(r.known_gated).toBe(true);
    expect(r.field_gated).toBe(true);
    expect(r.extra_gated).toBeNull();
  });
});
