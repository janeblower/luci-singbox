import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode, runUcodeJSON } from "../helpers/ucode.ts";

// Port of tests/backend/test_dns_schema_rpc.sh
// Validates that schema_dump.dump_all() includes a 'dns' key with all 14 DNS
// types, each having a fields array and sing_box_type, and that backend-only
// props do NOT leak through the FIELD_WHITELIST projection.
describe("dns schema RPC projection (schema_dump.dump_all)", () => {
  useGuest();

  it("dump_all() returns an object with a dns key", async () => {
    const out = await runUcodeJSON<Record<string, unknown>>(`
      let dump = require("builder.protocols.schema_dump").dump_all();
      print(sprintf("%J", dump));
    `);
    expect(typeof out.dns).toBe("object");
    expect(out.dns).not.toBeNull();
  });

  it("all 14 dns types present in dns projection", async () => {
    const out = await runUcodeJSON<Record<string, Record<string, unknown>>>(`
      let dump = require("builder.protocols.schema_dump").dump_all();
      print(sprintf("%J", dump.dns));
    `);
    const expectedTypes = [
      "udp",
      "tls",
      "https",
      "fakeip",
      "legacy",
      "tcp",
      "quic",
      "h3",
      "local",
      "hosts",
      "dhcp",
      "mdns",
      "tailscale",
      "resolved",
    ];
    for (const t of expectedTypes) {
      expect(out[t]).not.toBeNull();
      expect(out[t]).toBeDefined();
    }
  });

  it("each dns type has fields[] array and sing_box_type string", async () => {
    const dns = await runUcodeJSON<
      Record<string, { fields: unknown[]; sing_box_type: string }>
    >(`
      let dump = require("builder.protocols.schema_dump").dump_all();
      print(sprintf("%J", dump.dns));
    `);
    const errs: string[] = [];
    for (const [t, entry] of Object.entries(dns)) {
      if (!Array.isArray(entry.fields)) errs.push(`${t}: missing fields[]`);
      if (entry.sing_box_type == null) errs.push(`${t}: missing sing_box_type`);
    }
    expect(errs).toEqual([]);
  });

  it("no backend-only props leak through FIELD_WHITELIST projection", async () => {
    const dns = await runUcodeJSON<
      Record<string, { fields: Record<string, unknown>[] }>
    >(`
      let dump = require("builder.protocols.schema_dump").dump_all();
      print(sprintf("%J", dump.dns));
    `);
    const backendProps = [
      "json_key",
      "coerce",
      "omit_when",
      "skip_value",
      "requires",
      "default_when_empty",
      "only_values",
    ];
    const leaks: string[] = [];
    for (const [t, entry] of Object.entries(dns)) {
      if (!Array.isArray(entry.fields)) continue;
      for (const f of entry.fields) {
        for (const bp of backendProps) {
          if (f[bp] != null) leaks.push(`dns.${t}.${f.name ?? "?"}:${bp}`);
        }
      }
    }
    expect(leaks).toEqual([]);
  });

  it("fakeip descriptor exposes nft_rules bool field (UI/UCI-only; no json_key)", async () => {
    const src = `
      let dump = require("builder.protocols.schema_dump").dump_all();
      let dns = dump.dns;
      let fakeip = dns["fakeip"];
      if (fakeip == null) { warn("fakeip entry missing\\n"); exit(1); }
      let found = 0;
      for (let f in (fakeip.fields || [])) {
        if (f.name === "nft_rules" && f.type === "bool") { found = 1; break; }
      }
      if (!found) { warn("nft_rules bool field missing from fakeip schema\\n"); exit(1); }
      print("OK\\n");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("OK");
  });
});
