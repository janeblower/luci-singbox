import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

// Extra -L dir so require("subscription") resolves subscription.uc
const SHARE = "/tmp/work/singbox-ui/root/usr/share/singbox-ui";

describe("test_subscription_unit", () => {
  useGuest();

  // S3-6 used to poke subscription.uc's try_b64_decode, which decided whether a
  // body was base64 by looking for a share-link scheme in the DECODED text. That
  // heuristic is gone: lib/subformat.uc decodes and PARSES, and a payload that
  // yields no node is simply not a subscription. Same two cases, same guarantee.
  it("S3-6: a scheme-bearing base64 body decodes into nodes", async () => {
    const r = await runUcode(
      `
let sf = require("subformat");
// b64("vless://uuid@host:443\\n")
let res = sf.parse_body("dmxlc3M6Ly91dWlkQGhvc3Q6NDQzCg==", 0);
printf("%s %d\\n", res.format, length(res.nodes));
`,
      [],
      [SHARE],
    );
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("uri 1");
  });

  it("S3-6: base64 of a plaintext page yields no nodes (never mistaken for a feed)", async () => {
    const r = await runUcode(
      `
let sf = require("subformat");
// b64("visit https://example.com/path") — plaintext, no proxy URL anywhere.
let res = sf.parse_body("dmlzaXQgaHR0cHM6Ly9leGFtcGxlLmNvbS9wYXRo", 0);
printf("%d\\n", length(res.nodes));
`,
      [],
      [SHARE],
    );
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("0");
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
