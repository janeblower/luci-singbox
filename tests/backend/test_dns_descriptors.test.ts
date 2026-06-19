import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

// Port of tests/backend/test_dns_descriptors.sh
// Verifies that builder.dns.registry eager-loads all 14 DNS server descriptors
// and registers them under the "dns" kind.
describe("dns descriptors (builder.dns.registry)", () => {
  useGuest();

  it("registers all 14 DNS types with no missing entries", async () => {
    const src = `
      require("builder.dns.registry");
      let reg = require("builder.protocols.registry");
      let want = ["udp","tcp","tls","quic","https","h3","fakeip","local","hosts","dhcp","mdns","tailscale","resolved","legacy"];
      let got = reg.types_for_kind("dns");
      let set = {}; for (let t in got) set[t] = 1;
      let missing = [];
      for (let w in want) if (!set[w]) push(missing, w);
      if (length(missing)) { print("MISSING:" + join(",", missing) + "\\n"); exit(1); }
      print("count=" + length(got) + "\\n");
      print("OK\\n");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).not.toContain("MISSING:");
    expect(r.stdout).toContain("count=14");
    expect(r.stdout).toContain("OK");
  });
});
