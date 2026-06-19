import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

// Port of tests/backend/test_post_process_uc.sh
const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const FIXTURES_LIB = `${WORK}/tests/fixtures`;

describe("post_process_uc (post_process.scrub_implicit_refs + run_pipeline)", () => {
  useGuest();

  it("scrub_implicit_refs: dns detour scrubbed; route ref to real implicit direct kept", async () => {
    const r = await runUcode(`
let pp = require("post_process");
let cfg = {
    outbounds: [{ type: "direct", tag: "direct" }],
    dns: { servers: [{ tag: "ns1", detour: "direct" }] },
    route: { final: "direct", rules: [{ outbound: "direct" }] }
};
let res = pp.scrub_implicit_refs(cfg, { implicit_tags: ["direct"] });
print(((res.dns.servers[0].detour ?? "(absent)") == "(absent)" || res.dns.servers[0].detour === null ? "scrubbed" : res.dns.servers[0].detour) + "\\n");
print(((res.route.final ?? "(absent)") == "(absent)" || res.route.final === null ? "scrubbed" : res.route.final) + "\\n");
print(((res.route.rules[0].outbound ?? "(absent)") == "(absent)" || res.route.rules[0].outbound === null ? "scrubbed" : res.route.rules[0].outbound) + "\\n");
`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("scrubbed\ndirect\ndirect");
  });

  it("scrub_implicit_refs: route ref to a DANGLING implicit tag IS scrubbed", async () => {
    const r = await runUcode(`
let pp = require("post_process");
let cfg = {
    outbounds: [{ type: "vless", tag: "p" }],
    route: { final: "ghost", rules: [{ outbound: "ghost" }] }
};
let res = pp.scrub_implicit_refs(cfg, { implicit_tags: ["ghost"] });
print(((res.route.final ?? "(absent)") == "(absent)" || res.route.final === null ? "scrubbed" : res.route.final) + "\\n");
print(((res.route.rules[0].outbound ?? "(absent)") == "(absent)" || res.route.rules[0].outbound === null ? "scrubbed" : res.route.rules[0].outbound) + "\\n");
`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("scrubbed\nscrubbed");
  });

  it("scrub_implicit_refs no-op when implicit_tags empty", async () => {
    const r = await runUcode(`
let pp = require("post_process");
let res = pp.scrub_implicit_refs({
    dns: { servers: [{ tag: "ns1", detour: "direct" }] }
}, { implicit_tags: [] });
print(res.dns.servers[0].detour);
`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("direct");
  });

  it("run_pipeline is idempotent", async () => {
    const r = await runUcode(`
let pp = require("post_process");
let cfg = { dns: { servers: [{ tag: "n", detour: "direct" }] } };
pp.run_pipeline(cfg, { implicit_tags: ["direct"] });
pp.run_pipeline(cfg, { implicit_tags: ["direct"] });
print(cfg.dns.servers[0].detour === null || cfg.dns.servers[0].detour === undefined ? "scrubbed" : cfg.dns.servers[0].detour);
`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("scrubbed");
  });

  it("run_pipeline invokes registered plugin hooks (noop fixture)", async () => {
    const r = await runUcode(
      `
require("plugins.noop");
let pp = require("post_process");
pp.run_pipeline({ route: { rules: [] } }, { generation_ts: 12345 });
assert(global._test_noop_called != null, "noop plugin not invoked");
assert(global._test_noop_called.ts === 12345, "ctx.generation_ts not passed");
assert(global._test_noop_called.had_config === true, "config not passed");
print("PASS test_post_process_uc plugin invocation\\n");
`,
      [],
      // extra lib dirs: tests/fixtures (noop plugin lives there)
      [FIXTURES_LIB],
    );
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("PASS test_post_process_uc plugin invocation");
  });
});
