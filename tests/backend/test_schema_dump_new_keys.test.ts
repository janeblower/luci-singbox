import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

// Port of tests/backend/test_schema_dump_new_keys.sh
// Asserts that max_version is in FIELD_WHITELIST and that dump_all()
// exposes the cache, clash_api, and dns_rule keys.

describe("schema dump new keys", () => {
  useGuest();

  it("max_version is whitelisted and dump_all has cache/clash_api/dns_rule", async () => {
    const src = `
let sd = require("builder.protocols.schema_dump");
let found = false;
for (let k in sd.FIELD_WHITELIST) if (k === "max_version") found = true;
if (!found) { print("FAIL: max_version not whitelisted\\n"); exit(1); }
let all = sd.dump_all();
for (let k in [ "cache", "clash_api", "dns_rule" ])
  if (!(k in all)) { print(sprintf("FAIL: dump_all missing %s\\n", k)); exit(1); }
print("OK\\n");
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("OK");
  });
});
