import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

describe("test_cache_dispatch", () => {
  useGuest();

  it("build_cache dispatches storage, fakeip gate, and disabled returns null", async () => {
    const src = `
let cache = require("cache");
let CFG = {
  cache: { [".name"]: "cache", enabled: "1", storage: "custom", path: "/srv/c.db", store_fakeip: "1" },
  dns_server: [ { [".name"]: "f1", enabled: "1", type: "fakeip" } ],
};
let cur = {
  get_all: function(_p, t) { return CFG[t]; },
  foreach: function(_p, t, fn) { for (let s in (CFG[t] || [])) fn(s); },
};
let out = cache.build_cache(cur);
if (out.path != "/srv/c.db") { print(sprintf("FAIL path=%s\\n", out.path)); exit(1); }
if (out.store_fakeip != true) { print("FAIL fakeip kept\\n"); exit(1); }
CFG.dns_server = [ { [".name"]: "f1", enabled: "0", type: "fakeip" } ];
out = cache.build_cache(cur);
if ("store_fakeip" in out) { print("FAIL store_fakeip not gated\\n"); exit(1); }
CFG.cache = { [".name"]: "cache", enabled: "1", storage: "ram" };
out = cache.build_cache(cur);
if (out.path != "/tmp/singbox-ui-cache.db") { print(sprintf("FAIL ram path=%s\\n", out.path)); exit(1); }
CFG.cache = { [".name"]: "cache", enabled: "0" };
if (cache.build_cache(cur) != null) { print("FAIL: disabled not null\\n"); exit(1); }
print("OK\\n");
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("OK");
  });
});
