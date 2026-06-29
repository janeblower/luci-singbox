/**
 * tests/cross/test_awg_acl.test.ts
 *
 * Package-shape smoke test for singbox-ui-plugin-awg_warp.
 * Verifies the ACL file is present and contains the expected read/write split.
 * Host-only (file-read shape test via node:fs; no VM needed).
 * Expanded by Task 9 to cover the full plugin backend surface.
 */

import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

const ROOT = process.env.SB_REPO
  ? resolve(process.env.SB_REPO)
  : resolve(import.meta.dirname, "../..");

const ACL = resolve(
  ROOT,
  "plugins/awg_warp/root/usr/share/rpcd/acl.d/singbox-ui-plugin-awg_warp.json",
);

describe("awg-warp package shape", () => {
  it("ships an acl.d file with a singbox-ui ubus section", () => {
    expect(existsSync(ACL)).toBe(true);
    const j = JSON.parse(readFileSync(ACL, "utf8"));
    const role = j["singbox-ui-plugin-awg_warp"];
    expect(role).toBeTruthy();
    expect(role.read.ubus["singbox-ui"]).toContain("awg_status");
    expect(role.write.ubus["singbox-ui"]).toContain("awg_install");
    expect(role.write.ubus["singbox-ui"]).not.toContain("warp_register");
    expect(role.write.ubus["singbox-ui"]).not.toContain("awg_generate");
  });

  // The feed key is NOT bundled — it is fetched dynamically by the provisioning
  // script (awg-provision.sh); that flow is covered by tests/backend/test_awg_install.
});
