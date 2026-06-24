import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

describe("test_sharelink_flow_when_gate", () => {
  useGuest();

  // vless with flow but no security -> flow omitted (SLM-3 regression)
  it("vless flow without security omits flow field", async () => {
    const src = `
let r = require("sharelink").parse_proxy_url("vless://11111111-1111-1111-1111-111111111111@h.ex:443?flow=xtls-rprx-vision#n");
print(r.flow == null ? "OMIT" : "LEAK");
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("OMIT");
  });

  // vless with flow AND security=tls -> flow present
  it("vless flow with security=tls emits flow field", async () => {
    const src = `
let r = require("sharelink").parse_proxy_url("vless://11111111-1111-1111-1111-111111111111@h.ex:443?security=tls&flow=xtls-rprx-vision#n");
print(r.flow ?? "MISSING");
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("xtls-rprx-vision");
  });

  // vless with flow AND security=reality -> flow present
  it("vless flow with security=reality emits flow field", async () => {
    const src = `
let r = require("sharelink").parse_proxy_url("vless://11111111-1111-1111-1111-111111111111@h.ex:443?security=reality&pbk=PUBKEY&flow=xtls-rprx-vision#n");
print(r.flow ?? "MISSING");
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("xtls-rprx-vision");
  });
});
