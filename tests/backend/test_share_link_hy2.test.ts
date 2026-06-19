import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

describe("test_share_link_hy2", () => {
  useGuest();

  it("hysteria2:// full URL parses password, host, port, obfs", async () => {
    const src = `
let o = require("outbound");
let r = o.parse_proxy_url("hysteria2://hy2pass@example.com:443?obfs=salamander&obfs-password=opass#hy2srv");
print(sprintf("%s|%s|%d|%s|%s|%s", r.type, r.server, r.server_port, r.password, r.obfs.type, r.obfs.password));
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe(
      "hysteria2|example.com|443|hy2pass|salamander|opass",
    );
  });

  it("hy2:// short scheme alias parses correctly", async () => {
    const src = `
let o = require("outbound");
let r = o.parse_proxy_url("hy2://secret@10.0.0.1:8443#mynode");
print(sprintf("%s|%s|%d|%s", r.type, r.server, r.server_port, r.password));
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("hysteria2|10.0.0.1|8443|secret");
  });
});
