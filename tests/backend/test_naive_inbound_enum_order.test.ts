import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

// Regression test for prot-6: naive inbound network enum order
// Verifies that the inbound network enum is [tcp, udp] (not [udp, tcp])
// to match outbound and all other protocols.

describe("naive inbound enum order (prot-6)", () => {
  useGuest();

  it("naive inbound with network=tcp works correctly", async () => {
    const golden =
      '{ "type": "naive", "tag": "nv_tcp", "listen": "::", "listen_port": 443, "network": "tcp", "users": [ { "username": "alice", "password": "secret" } ], "tls": { "enabled": true, "certificate_path": "/c.pem", "key_path": "/k.pem" } }';
    const r = await runUcode(`
let inb = require("inbound");
let s = { ".name":"nv_tcp", "protocol":"naive", "listen_port":"443", "network":"tcp",
          "naive_user":["alice:secret"],
          "tls_enabled":"1", "tls_certificate_path":"/c.pem", "tls_key_path":"/k.pem" };
printf("%J", inb.build_one(s));
`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe(golden);
  });

  it("naive inbound with network=udp works correctly", async () => {
    const golden =
      '{ "type": "naive", "tag": "nv_udp", "listen": "::", "listen_port": 443, "network": "udp", "users": [ { "username": "alice", "password": "secret" } ], "tls": { "enabled": true, "certificate_path": "/c.pem", "key_path": "/k.pem" } }';
    const r = await runUcode(`
let inb = require("inbound");
let s = { ".name":"nv_udp", "protocol":"naive", "listen_port":"443", "network":"udp",
          "naive_user":["alice:secret"],
          "tls_enabled":"1", "tls_certificate_path":"/c.pem", "tls_key_path":"/k.pem" };
printf("%J", inb.build_one(s));
`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe(golden);
  });
});
