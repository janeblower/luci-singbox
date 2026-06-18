import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcodeJSON } from "../helpers/ucode.ts";

// Port of tests/backend/test_dns_filler.sh
// Registers a minimal "tls" DNS-server descriptor and verifies the declarative
// filler emits the expected sing-box JSON fields.
describe("dns filler (declarative DoT server)", () => {
  useGuest();

  it("builds a DoT server with dial detour + tls block", async () => {
    const src = `
      let reg = require("builder.protocols.registry");
      let filler = require("builder._filler");
      reg.register({
        kind: "dns", type: "tls", sing_box_type: "tls",
        shared: { dial: {}, tls: {} },
        fields: [
          { name: "server", type: "string", tab: "basic", json_key: "server", omit_when: "never" },
          { name: "server_port", type: "number", tab: "basic", json_key: "server_port", coerce: "num" },
        ],
      });
      let d = reg.get("dns", "tls");
      let s = { [".name"]: "dot1", server: "1.1.1.1", server_port: "853",
                detour: "proxy", tls_enabled: "1", tls_server_name: "cloudflare-dns.com" };
      let out = filler.build(d, s);
      print(sprintf("%J", out));
    `;
    const out = await runUcodeJSON<Record<string, unknown>>(src);

    // Shell: grep '"type"' && grep 'tls'
    expect(out.type).toBe("tls");
    // Shell: grep '"tag"' && grep 'dot1'
    expect(out.tag).toBe("dot1");
    // Shell: grep '"server"' && grep '1.1.1.1'
    expect(out.server).toBe("1.1.1.1");
    // Shell: grep '"detour"' && grep 'proxy' (dial block merged flat)
    expect(out.detour).toBe("proxy");
    // Shell: grep '"tls"' (dns -> outbound tls direction)
    expect(out.tls).toBeDefined();
  });
});
