import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

// Port of tests/backend/test_version_gating.sh
// Schema carries min_version for gated protocols; checks anytls/naive/cloudflared.
// naive inbound is intentionally ungated (empty string).

describe("version gating", () => {
  useGuest();

  it("min_version projection correct for gated protocols", async () => {
    const src = `
require("outbound"); require("inbound");
let d = require("builder.protocols.schema_dump").dump_all();
print(sprintf("anytls=%s naive_out=%s naive_in=%s cloudflared=%s\\n",
    d.outbound.anytls.min_version,
    d.outbound.naive.min_version,
    d.inbound.naive.min_version,
    d.inbound.cloudflared.min_version));
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain(
      "anytls=1.12 naive_out=1.13 naive_in= cloudflared=1.14",
    );
  });
});
