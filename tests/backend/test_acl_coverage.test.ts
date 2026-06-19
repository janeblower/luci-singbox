import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec } from "../helpers/ssh.ts";

// Port of tests/backend/test_acl_coverage.sh
// Every method in read.ubus must be on the SAFE_READ_METHODS whitelist.
// Every method in write.ubus must be on EXPECTED_WRITE_METHODS.
// No method may appear in both lists.

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const ACL = `${WORK}/luci-app-singbox-ui/root/usr/share/rpcd/acl.d/luci-singbox-ui.json`;

// Hardcoded invariant — MUST stay hand-maintained. See CLAUDE.md.
const SAFE_READ_METHODS = [
  "status",
  "status_detail",
  "sub_status",
  "read_config",
  "clash_get",
  "clash_delay",
  "export_section",
  "preview_config",
  "protocol_schema",
];

const EXPECTED_WRITE_METHODS = [
  "generate",
  "nftables",
  "restart",
  "refresh",
  "clash_mutate",
];

describe("test_acl_coverage", () => {
  useGuest();

  it("parses ACL JSON and extracts read/write method lists", async () => {
    const r = await exec(`
      ucode -e '
        let fs = require("fs");
        let d = json(fs.readfile("${ACL}") || "{}");
        let o = d["luci-singbox-ui"] ?? {};
        let read_arr = ((o.read ?? {}).ubus ?? {})["singbox-ui"] ?? [];
        let write_arr = ((o.write ?? {}).ubus ?? {})["singbox-ui"] ?? [];
        let read = []; for (let m in read_arr) push(read, m);
        let write = []; for (let m in write_arr) push(write, m);
        print(sprintf("%J", {read, write}));
      '
    `);
    expect(r.exitCode).toBe(0);

    const { read, write } = JSON.parse(r.stdout) as {
      read: string[];
      write: string[];
    };
    expect(read.length).toBeGreaterThan(0);
    expect(write.length).toBeGreaterThan(0);

    // Every read method must be on the safe-for-read whitelist
    for (const m of read) {
      expect(
        SAFE_READ_METHODS.includes(m),
        `method '${m}' is in read.ubus but not on SAFE_READ_METHODS`,
      ).toBe(true);
    }

    // Every write method must be on the expected whitelist
    for (const m of write) {
      expect(
        EXPECTED_WRITE_METHODS.includes(m),
        `method '${m}' is in write.ubus but not in EXPECTED_WRITE_METHODS`,
      ).toBe(true);
    }

    // No method may be in both lists (the clash_request bug class)
    for (const m of read) {
      expect(
        write.includes(m),
        `method '${m}' is in both read.ubus and write.ubus`,
      ).toBe(false);
    }

    // Regression: legacy clash_request must not appear anywhere
    expect(read.includes("clash_request")).toBe(false);
    expect(write.includes("clash_request")).toBe(false);
  });
});
