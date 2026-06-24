/**
 * tests/cross/test_awg_acl.test.ts
 *
 * Package-shape smoke test for luci-app-singbox-plugin-awg-warp.
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
  "luci-app-singbox-plugin-awg-warp/root/usr/share/rpcd/acl.d/luci-singbox-plugin-awg-warp.json",
);

const PEM = resolve(
  ROOT,
  "luci-app-singbox-plugin-awg-warp/root/usr/share/singbox-ui/lib/plugins/awg_warp/awg-openwrt-feed.pem",
);

describe("awg-warp package shape", () => {
  it("ships an acl.d file with a singbox-ui ubus section", async () => {
    const f = Bun.file(ACL);
    expect(await f.exists()).toBe(true);
    const j = JSON.parse(await f.text());
    const role = j["luci-singbox-plugin-awg-warp"];
    expect(role).toBeTruthy();
    expect(role.read.ubus["singbox-ui"]).toContain("awg_status");
    expect(role.write.ubus["singbox-ui"]).toContain("warp_register");
    expect(role.write.ubus["singbox-ui"]).toContain("awg_install");
    expect(role.write.ubus["singbox-ui"]).toContain("awg_generate");
  });

  it("bundles the awg-openwrt feed signing key as a PEM public key", async () => {
    const f = Bun.file(PEM);
    expect(await f.exists()).toBe(true);
    const text = await f.text();
    expect(text).toMatch(/^-----BEGIN PUBLIC KEY-----/);
    expect(text).toMatch(/-----END PUBLIC KEY-----/);
  });
});
