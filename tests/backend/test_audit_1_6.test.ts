import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

// Port of tests/backend/test_audit_1_6.sh
// Regression for audit 1.6: descriptor input validation / UX hardening.
//   - shadowsocks ss_user: warn()+skip entries with unknown method or empty pw
//   - vless inbound_user: warn()+skip structurally-malformed uuid tokens

describe("audit 1.6 (descriptor input validation: ss_user / inbound_user)", () => {
  useGuest();

  async function runBuild(sLiteral: string) {
    return runUcode(`
let inb = require("inbound");
let s = ${sLiteral};
printf("%J", inb.build_one(s));
`);
  }

  // ---- shadowsocks: unknown method warn+skip, valid kept ----
  it("ss_user: unknown method is dropped (warn), valid user kept", async () => {
    const r = await runBuild(`{
  ".name":"ss", "protocol":"shadowsocks", "listen":"::", "listen_port":"8388",
  "shadowsocks_method":"aes-128-gcm",
  "ss_user":["bad:made-up-cipher:pw","good:aes-256-gcm:gp"]
}`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain('"name": "good"');
    expect(r.stdout).toContain('"password": "gp"');
    expect(r.stdout).not.toContain('"name": "bad"');
    expect(r.stderr).toContain("unknown method 'made-up-cipher'");
  });

  it("ss_user: empty password is dropped (warn), valid user kept", async () => {
    const r = await runBuild(`{
  ".name":"ss", "protocol":"shadowsocks", "listen":"::", "listen_port":"8388",
  "shadowsocks_method":"aes-128-gcm",
  "ss_user":["empty:aes-128-gcm:","good:aes-128-gcm:gp"]
}`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain('"name": "good"');
    expect(r.stdout).not.toContain('"name": "empty"');
    expect(r.stderr).toMatch(/empty.*password|password.*empty/);
  });

  // ---- vless inbound_user: malformed uuid warn+skip ----
  it("inbound_user (vless): whitespace-uuid is dropped (warn), valid kept", async () => {
    const r = await runBuild(`{
  ".name":"vl", "protocol":"vless", "listen":"::", "listen_port":"443",
  "inbound_user":["bad user:has space","good:11223344-5566-7788-9900-aabbccddeeff"]
}`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain('"name": "good"');
    expect(r.stdout).not.toContain('"name": "bad user"');
    // A warn should appear on stderr for the malformed entry
    expect(r.stderr).toBeTruthy();
  });

  it("inbound_user (vless): non-UUID-class chars dropped (warn), valid kept", async () => {
    const r = await runBuild(`{
  ".name":"vl", "protocol":"vless", "listen":"::", "listen_port":"443",
  "inbound_user":["bad:not!a!uuid","good:11223344-5566-7788-9900-aabbccddeeff"]
}`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain('"name": "good"');
    expect(r.stdout).not.toContain('"name": "bad"');
    expect(r.stderr).toBeTruthy();
  });

  it("inbound_user (vless): non-canonical but clean hex-hyphens token NOT dropped", async () => {
    // The check is intentionally loose: only clearly-broken tokens are dropped.
    const r = await runBuild(`{
  ".name":"vl", "protocol":"vless", "listen":"::", "listen_port":"443",
  "inbound_user":["ok:aabbccddeeff11223344556677889900"]
}`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain('"name": "ok"');
  });
});
