import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcodeJSON } from "../helpers/ucode.ts";

// Port of tests/backend/test_protocol_users.sh
// Universal declarative users builder (_shared/users.uc):
//   API: U.build(s, spec) → { users: [...], from_list: bool }
//   spec = { from, columns, single_fallback? }
//   single_fallback = { fields: [ { key, from } ] }

describe("protocol users builder", () => {
  useGuest();

  // ---- mixed: username:password ----
  it("mixed multi-user: alice:wonderland, bob:builder", async () => {
    const src = `
      let U = require("builder._shared.users");
      let spec = { from: "mixed_user", columns: [
        { key: "username", required: true },
        { key: "password", tail: true, always: true },
      ] };
      let s = { ".name": "m", mixed_user: ["alice:wonderland", "bob:builder"] };
      let r = U.build(s, spec);
      print(sprintf("%J", r.users));
    `;
    const got =
      await runUcodeJSON<Array<{ username: string; password: string }>>(src);
    expect(got).toHaveLength(2);
    expect(got[0].username).toBe("alice");
    expect(got[0].password).toBe("wonderland");
    expect(got[1].username).toBe("bob");
    expect(got[1].password).toBe("builder");
  });

  it("mixed: colon-in-password preserved (tail captures rest)", async () => {
    const src = `
      let U = require("builder._shared.users");
      let spec = { from: "mixed_user", columns: [
        { key: "username", required: true },
        { key: "password", tail: true, always: true },
      ] };
      let s = { ".name": "m", mixed_user: ["alice:pass:with:colons"] };
      let r = U.build(s, spec);
      print(sprintf("%J", r.users));
    `;
    const got =
      await runUcodeJSON<Array<{ username: string; password: string }>>(src);
    expect(got).toHaveLength(1);
    expect(got[0].username).toBe("alice");
    expect(got[0].password).toBe("pass:with:colons");
  });

  it("mixed: empty list → no users key", async () => {
    const src = `
      let U = require("builder._shared.users");
      let spec = { from: "mixed_user", columns: [
        { key: "username", required: true },
        { key: "password", tail: true, always: true },
      ] };
      let s = { ".name": "m" };
      let r = U.build(s, spec);
      print(sprintf("%J", r.users));
    `;
    const got = await runUcodeJSON<unknown>(src);
    const arr = Array.isArray(got) ? got : [];
    expect(arr).toHaveLength(0);
  });

  // ---- vless multi ----
  it("vless multi-user: valid rows included, bad rows (malformed uuid, missing uuid) skipped", async () => {
    // Shell test uses "bad: " (space in uuid) and "carol:uuid c" (space) to trigger guard.
    // The guard rejects UUIDs containing characters outside [0-9A-Za-z-].
    const src = `
      let U = require("builder._shared.users");
      let spec = { from: "inbound_user", columns: [
        { key: "name", required: true },
        { key: "uuid", required: true, guard: "uuid" },
        { key: "flow", tail: true },
      ] };
      let s = { ".name": "v", inbound_user: [
        "alice:uuid-a:xtls-rprx-vision",
        "bob:uuid-b",
        "bad: ",
        "carol:uuid c",
      ] };
      let r = U.build(s, spec);
      print(sprintf("%J", r.users));
    `;
    const got = await runUcodeJSON<Array<{ name: string; uuid: string }>>(src);
    // alice and bob survive; bad (space in uuid) and carol (space in uuid) are skipped
    expect(got.length).toBe(2);
    expect(got[0].name).toBe("alice");
    expect(got[0].uuid).toBe("uuid-a");
    expect(got[1].name).toBe("bob");
    expect(got[1].uuid).toBe("uuid-b");
  });

  it("vless single fallback when list empty", async () => {
    const src = `
      let U = require("builder._shared.users");
      let spec = { from: "inbound_user",
        columns: [
          { key: "name", required: true },
          { key: "uuid", required: true, guard: "uuid" },
        ],
        single_fallback: { fields: [ { key: "uuid", from: "server_uuid" } ] },
      };
      let s = { ".name": "v1", server_uuid: "11111111-2222-3333-4444-555555555555" };
      let r = U.build(s, spec);
      print(sprintf("%J", r.users));
    `;
    const got = await runUcodeJSON<Array<{ name: string; uuid: string }>>(src);
    expect(got).toHaveLength(1);
    expect(got[0].uuid).toBe("11111111-2222-3333-4444-555555555555");
  });

  // ---- shadowsocks: name:method:password ----
  it("shadowsocks multi-user: method validated and discarded, invalid method skipped", async () => {
    const src = `
      let U = require("builder._shared.users");
      let spec = { from: "ss_user", columns: [
        { key: "name", required: true },
        { key: "method", validate: ["2022-blake3-aes-128-gcm","2022-blake3-aes-256-gcm","2022-blake3-chacha20-poly1305","aes-256-gcm","chacha20-ietf-poly1305"], discard: true },
        { key: "password", tail: true, warn_if_empty: true },
      ] };
      let s = { ".name": "ss", ss_user: [
        "alice:2022-blake3-aes-128-gcm:p@ssw0rd",
        "bob:invalid-method:pw",
        "carol:chacha20-ietf-poly1305:mypass",
      ] };
      let r = U.build(s, spec);
      print(sprintf("%J", r.users));
    `;
    const got =
      await runUcodeJSON<Array<{ name: string; password: string }>>(src);
    // alice and carol pass (valid methods); bob is skipped
    expect(got.length).toBe(2);
    expect(got[0].name).toBe("alice");
    expect(got[0].password).toBe("p@ssw0rd");
    expect(got[1].name).toBe("carol");
    expect(got[1].password).toBe("mypass");
    // method must NOT appear in output (discarded)
    expect((got[0] as Record<string, unknown>).method).toBeUndefined();
  });

  // ---- trojan single ----
  it("trojan single (no list): single user from server_password", async () => {
    const src = `
      let U = require("builder._shared.users");
      let spec = { from: "inbound_user",
        columns: [ { key: "name", required: true }, { key: "password", tail: true } ],
        single_fallback: { fields: [ { key: "password", from: "server_password" } ] },
      };
      let s = { ".name": "tj", server_password: "secret-pw" };
      let r = U.build(s, spec);
      print(sprintf("%J", r.users));
    `;
    const got =
      await runUcodeJSON<Array<{ name: string; password: string }>>(src);
    expect(got).toHaveLength(1);
    expect(got[0].password).toBe("secret-pw");
  });

  // ---- BLD-5: single_fallback with ALL source fields empty must NOT emit user ----
  it("BLD-5: single_fallback with all source fields empty emits no user", async () => {
    const src = `
      let U = require("builder._shared.users");
      let spec = { from: "inbound_user",
        columns: [ { key: "name", required: true }, { key: "password", tail: true } ],
        single_fallback: { fields: [ { key: "password", from: "server_password" } ] },
      };
      // server_password absent
      let s = { ".name": "tj" };
      let r = U.build(s, spec);
      print(sprintf("%J", r.users));
    `;
    const got = await runUcodeJSON<unknown>(src);
    const arr = Array.isArray(got) ? got : [];
    expect(arr).toHaveLength(0);
  });

  // ---- colon-less single token dropped — all families ----
  it("colon-less single token is dropped (mixed)", async () => {
    const src = `
      let U = require("builder._shared.users");
      let spec = { from: "mixed_user", columns: [
        { key: "username", required: true },
        { key: "password", tail: true, always: true },
      ] };
      let s = { ".name": "m", mixed_user: ["justtoken"] };
      let r = U.build(s, spec);
      print(sprintf("%J", r.users));
    `;
    const got = await runUcodeJSON<unknown>(src);
    const arr = Array.isArray(got) ? got : [];
    expect(arr).toHaveLength(0);
  });

  it("colon-less single token is dropped (vless)", async () => {
    const src = `
      let U = require("builder._shared.users");
      let spec = { from: "inbound_user", columns: [
        { key: "name", required: true },
        { key: "uuid", required: true, guard: "uuid" },
      ] };
      let s = { ".name": "v", inbound_user: ["justtoken"] };
      let r = U.build(s, spec);
      print(sprintf("%J", r.users));
    `;
    const got = await runUcodeJSON<unknown>(src);
    const arr = Array.isArray(got) ? got : [];
    expect(arr).toHaveLength(0);
  });

  // ---- hysteria2 colon-less → dropped → single fallback fires ----
  it("hysteria2: colon-less entry dropped → single fallback fires with real server_password", async () => {
    const src = `
      let U = require("builder._shared.users");
      let spec = { from: "inbound_user",
        columns: [ { key: "name", required: true }, { key: "password", tail: true } ],
        single_fallback: { fields: [ { key: "password", from: "server_password" } ] },
      };
      // colon-less row is dropped; fallback provides the real password
      let s = { ".name": "h2", inbound_user: ["tokenonly"], server_password: "real-secret" };
      let r = U.build(s, spec);
      print(sprintf("%J", r.users));
    `;
    const got =
      await runUcodeJSON<Array<{ name: string; password: string }>>(src);
    expect(got).toHaveLength(1);
    expect(got[0].password).toBe("real-secret");
  });

  // ---- shadowsocks inbound: password (tail) contains a colon ----
  it("shadowsocks inbound: password (tail) contains a colon", async () => {
    const src = `
      let U = require("builder._shared.users");
      let spec = { from: "ss_user", columns: [
        { key: "name", required: true },
        { key: "method", validate: ["2022-blake3-aes-128-gcm","2022-blake3-aes-256-gcm","2022-blake3-chacha20-poly1305","aes-256-gcm","chacha20-ietf-poly1305"], discard: true },
        { key: "password", tail: true, warn_if_empty: true },
      ] };
      let s = { ".name": "ss", ss_user: ["alice:2022-blake3-aes-128-gcm:pass:with:colons"] };
      let r = U.build(s, spec);
      print(sprintf("%J", r.users));
    `;
    const got =
      await runUcodeJSON<Array<{ name: string; password: string }>>(src);
    expect(got).toHaveLength(1);
    expect(got[0].name).toBe("alice");
    expect(got[0].password).toBe("pass:with:colons");
  });

  // ---- end-to-end via inbound builder: vless inbound with multi-user ----
  it("end-to-end vless inbound: multi-user list via inbound.build_one", async () => {
    const src = `
      let inb = require("inbound");
      let s = {
        ".name": "vless_in", ".type": "inbound",
        enabled: "1", protocol: "vless",
        listen: "::", listen_port: "443",
        inbound_user: [
          "alice:11111111-2222-3333-4444-555555555555",
          "bob:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
        ],
      };
      let got = inb.build_one(s);
      print(sprintf("%J", got));
    `;
    const got = await runUcodeJSON<Record<string, unknown>>(src);
    expect(got.type).toBe("vless");
    const users = got.users as Array<{ uuid: string }>;
    expect(users).toHaveLength(2);
    expect(users[0].uuid).toBe("11111111-2222-3333-4444-555555555555");
    expect(users[1].uuid).toBe("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee");
  });
});
