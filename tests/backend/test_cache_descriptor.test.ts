import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

describe("test_cache_descriptor", () => {
  useGuest();

  it("cache descriptor is registered and filler builds correct output", async () => {
    const src = `
require("builder.settings.registry");
let reg = require("builder.protocols.registry");
let filler = require("builder._filler");
let d = reg.get("cache", "cache");
if (d == null) { print("FAIL: not registered\\n"); exit(1); }
let s = { [".name"]: "cache", enabled: "1", storage: "ram", store_fakeip: "1",
          store_rdrc: "1", rdrc_timeout: "5m", cache_id: "id1" };
let out = filler.build(d, s);
if (out.enabled != true) { print("FAIL enabled\\n"); exit(1); }
if (out.store_fakeip != true) { print("FAIL store_fakeip\\n"); exit(1); }
if (out.store_rdrc != true) { print("FAIL store_rdrc\\n"); exit(1); }
if (out.rdrc_timeout != "5m") { print("FAIL rdrc_timeout\\n"); exit(1); }
if (out.cache_id != "id1") { print("FAIL cache_id\\n"); exit(1); }
if ("storage" in out) { print("FAIL storage leaked\\n"); exit(1); }
if ("path" in out) { print("FAIL path leaked from filler (must be dispatcher-added)\\n"); exit(1); }
let out2 = filler.build(d, { [".name"]: "cache", storage: "ram" });
if ("enabled" in out2) { print("FAIL: enabled emitted when unset\\n"); exit(1); }
print("OK\\n");
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("OK");
  });
});
