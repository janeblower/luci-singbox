import { describe, it, expect } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

// Extra -L dir so require("subscription") resolves subscription.uc
const SHARE = "/tmp/work/singbox-ui/root/usr/share/singbox-ui";

describe("test_subscription_unit", () => {
  useGuest();

  it("S3-6: try_b64_decode is exported and decodes scheme-bearing base64", async () => {
    const r = await runUcode(
      `
let sub = require("subscription");
// b64("vless://uuid@host:443\\n") — decoded line starts with a known scheme.
print(sub.try_b64_decode("dmxlc3M6Ly91dWlkQGhvc3Q6NDQzCg==") + "\\n");
`,
      [],
      [SHARE],
    );
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toMatch(/^vless:\/\/uuid@host:443/);
  });

  it("S3-6: try_b64_decode passes through non-scheme payloads unchanged", async () => {
    const r = await runUcode(
      `
let sub = require("subscription");
// b64("visit https://example.com/path") decodes to plaintext with no
// LINE starting with a scheme -> must be returned as the original b64.
let s = "dmlzaXQgaHR0cHM6Ly9leGFtcGxlLmNvbS9wYXRo";
print((sub.try_b64_decode(s) === s) ? "same" : "changed");
`,
      [],
      [SHARE],
    );
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("same");
  });

  it("S3-7: _set_io_for_test installs an injectable reader", async () => {
    const r = await runUcode(
      `
let sub = require("subscription");
if (type(sub._set_io_for_test) !== "function") { print("no-setter\\n"); exit(0); }
let seen = [];
sub._set_io_for_test(
  function(specs) { push(seen, "download:" + length(specs)); return 0; },
  function(path)  { push(seen, "read:" + path); return "vless://x@h:1\\n"; }
);
// Exercise the seam: the injected reader returns our canned body.
print(sub._read_raw_for_test("/tmp/whatever") + "\\n");
print(join(",", seen) + "\\n");
`,
      [],
      [SHARE],
    );
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toMatch(/^vless:\/\/x@h:1/);
    expect(r.stdout).toContain("read:/tmp/whatever");
  });
});
