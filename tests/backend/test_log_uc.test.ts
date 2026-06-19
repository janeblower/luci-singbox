import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

// Port of tests/backend/test_log_uc.sh
describe("log_uc (log.log_event + _set_logger_for_test)", () => {
  useGuest();

  it("log_event captures key/value pairs via mockable logger", async () => {
    const r = await runUcode(`
let log = require("log");
let captured = [];
log._set_logger_for_test(function(level, line) {
    push(captured, level + "|" + line);
});
log.log_event("info", "config.applied", { source: "rpcd", hash: "abc123" });
for (let l in captured) print(l + "\\n");
`);
    expect(r.exitCode).toBe(0);
    // level+event prefix: line starts with info| and contains event=config.applied
    expect(r.stdout).toMatch(/^info\|.*event=config\.applied/m);
    // kv pairs emitted
    expect(r.stdout).toContain("source=rpcd");
    expect(r.stdout).toContain("hash=abc123");
    // timestamp present
    expect(r.stdout).toMatch(/ts=\d/);
  });

  it("log_event quotes values with whitespace", async () => {
    const r = await runUcode(`
let log = require("log");
let captured = [];
log._set_logger_for_test(function(level, line) { push(captured, line); });
log.log_event("warn", "x", { msg: "hello world" });
print(captured[0] + "\\n");
`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toMatch(/msg="hello[^"]*"/);
  });
});
