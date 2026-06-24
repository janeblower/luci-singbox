import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

// Port of tests/backend/test_plugins_registry.sh
// Tests lib/plugins/registry.uc: register/get_all/invoke order;
// hook exceptions logged not propagated.

describe("plugins registry", () => {
  useGuest();

  it("register/get_all/invoke order and exception isolation", async () => {
    const src = `
let r = require("plugins.registry");

// Empty state.
assert(length(r.get_all()) === 0, "registry starts empty");

// Register two plugins.
let calls = [];
r.register({
    name: "a",
    on_generate_post: function(c, ctx) { push(calls, "a"); },
});
r.register({
    name: "b",
    on_generate_post: function(c, ctx) { push(calls, sprintf("b:%d", ctx.generation_ts)); },
});

assert(length(r.get_all()) === 2, "two plugins registered");

// Invoke runs hooks in registration order.
r.invoke_on_generate_post({}, { generation_ts: 42 });
assert(join(",", calls) === "a,b:42", "invoke order: " + join(",", calls));

// A throwing plugin must not break the chain.
r.register({
    name: "boom",
    on_generate_post: function() { die("explode"); },
});
r.register({
    name: "after_boom",
    on_generate_post: function() { push(calls, "after_boom"); },
});
r.invoke_on_generate_post({}, { generation_ts: 43 });
// "a", "b:43", "after_boom" should have been added (boom logged but not propagated).
assert(index(calls, "after_boom") >= 0, "plugin after throwing plugin still ran");

// Asserts on register contract.
let bad_caught = false;
try { r.register({ on_generate_post: function() {} }); }
catch (_) { bad_caught = true; }
assert(bad_caught, "register without name must throw");

// Phase E: hooks are optional — a name-only plugin is a valid no-op registration.
let nohook_ok = true;
try { r.register({ name: "no_hook" }); }
catch (_) { nohook_ok = false; }
assert(nohook_ok, "register without hooks must succeed (Phase E)");

// But a non-function on_generate_post must still be rejected.
bad_caught = false;
try { r.register({ name: "bad_hook", on_generate_post: 123 }); }
catch (_) { bad_caught = true; }
assert(bad_caught, "register with non-function on_generate_post must throw");

print("PASS test_plugins_registry\\n");
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("PASS test_plugins_registry");
  });
});
