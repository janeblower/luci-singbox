import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

// Port of tests/backend/test_raw_types.sh
describe("raw_types (json/sharelink outbound passthrough; json inbound passthrough)", () => {
  useGuest();

  it("json outbound: verbatim splice, section tag wins over embedded tag", async () => {
    const r = await runUcode(`
let ob = require("outbound");
let o = ob.build_constructor_for({".name":"vm","type":"json",
    "raw_json":"{\\"type\\":\\"vmess\\",\\"server\\":\\"e.com\\",\\"server_port\\":443,\\"uuid\\":\\"u\\",\\"tag\\":\\"EMBEDDED\\"}"}, "json");
print(sprintf("%s|%s|%s", o.type, o.tag, o.server));
`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("vmess|vm|e.com");
  });

  it("json outbound: invalid JSON dropped (null)", async () => {
    const r = await runUcode(`
let ob = require("outbound");
let o = ob.build_constructor_for({".name":"b","type":"json","raw_json":"not json"}, "json");
print(o == null ? "NULL" : "LEAK");
`);
    // exit code may be non-zero due to json() error, but output must be NULL
    expect(r.stdout.trim()).toBe("NULL");
  });

  it("json outbound: non-object JSON dropped", async () => {
    const r = await runUcode(`
let ob = require("outbound");
let o = ob.build_constructor_for({".name":"a","type":"json","raw_json":"[1,2,3]"}, "json");
print(o == null ? "NULL" : "LEAK");
`);
    expect(r.stdout.trim()).toBe("NULL");
  });

  it("sharelink outbound: parsed, section tag applied", async () => {
    const r = await runUcode(`
let ob = require("outbound");
let o = ob.build_constructor_for({".name":"lk","type":"sharelink",
    "raw_link":"vless://11111111-1111-1111-1111-111111111111@host.example:443?security=tls&sni=x#frag"}, "sharelink");
print(sprintf("%s|%s|%s", o.type, o.tag, o.server));
`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("vless|lk|host.example");
  });

  it("json inbound: verbatim splice, section tag applied", async () => {
    const r = await runUcode(`
let inb = require("inbound");
let i = inb.build_one({".name":"in1","protocol":"json",
    "raw_json":"{\\"type\\":\\"mixed\\",\\"listen\\":\\"::\\",\\"listen_port\\":2080}"});
print(sprintf("%s|%s|%s", i.type, i.tag, i.listen_port));
`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("mixed|in1|2080");
  });
});
