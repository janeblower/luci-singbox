/**
 * tests/cross/test_awg_acl.test.ts
 *
 * Package-shape smoke test for singbox-ui-plugin-awg_warp.
 * Verifies the ACL file is present and contains the expected read/write split.
 * Host-only (file-read shape test via Bun.file; no VM needed).
 * Expanded by Task 9 to cover the full plugin backend surface.
 */
import { describe, expect, it } from "bun:test";
import { resolve } from "node:path";

const ROOT = process.env.SB_REPO
  ? resolve(process.env.SB_REPO)
  : resolve(import.meta.dir, "../..");

const ACL = resolve(
  ROOT,
  "plugins/awg_warp/root/usr/share/rpcd/acl.d/singbox-ui-plugin-awg_warp.json",
);

describe("awg-warp package shape", () => {
  it("ships an acl.d file with a singbox-ui ubus section", async () => {
    const f = Bun.file(ACL);
    expect(await f.exists()).toBe(true);
    const j = JSON.parse(await f.text());
    const role = j["singbox-ui-plugin-awg_warp"];
    expect(role).toBeTruthy();
    expect(role.read.ubus["singbox-ui"]).toContain("awg_status");
    expect(role.write.ubus["singbox-ui"]).toContain("warp_register");
    expect(role.write.ubus["singbox-ui"]).toContain("awg_install");
    expect(role.write.ubus["singbox-ui"]).toContain("awg_generate");
  });

  // The feed key is NOT bundled — it is fetched dynamically by the provisioning
  // script (awg-provision.sh); that flow is covered by tests/backend/test_awg_install.
});
