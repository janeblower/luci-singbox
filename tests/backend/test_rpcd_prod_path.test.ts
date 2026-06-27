import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec } from "../helpers/ssh.ts";

// Port of tests/backend/test_rpcd_prod_path.sh
//
// Production-path regression: installs the handler + lib into the guest's
// REAL system paths, restarts rpcd, and calls `ubus call singbox-ui ...`.
// rpcd launches the handler via its shebang, exercising the `-L` flag that
// test_rpcd_handler.sh bypasses by calling `ucode -L` directly.
//
// VM-only: requires a live rpcd + ubus. On a plain host this is skipped.

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const SRC = `${WORK}/singbox-ui/root`;
const HANDLER_SRC = `${SRC}/usr/libexec/rpcd/singbox-ui`;
const ACL_SRC = `${WORK}/luci-app-singbox-ui/root/usr/share/rpcd/acl.d/luci-singbox-ui.json`;
const SEED_NAME = "prodpath_probe_in";

const IN_VM = process.env.SINGBOX_TESTS_IN_VM === "1";

// Helper: assert a method returned a clean JSON envelope (no require() failure)
async function assertClean(method: string, out: string): Promise<void> {
  // A require() failure surfaces as a message containing "require(" + "error"
  if (out.includes("require(") && out.includes('"error"')) {
    throw new Error(
      `${method} hit a require() failure via prod path; out=${out}`,
    );
  }
  expect(out, `${method} must return a JSON status envelope`).toContain(
    '"status"',
  );
}

describe("test_rpcd_prod_path", () => {
  useGuest();

  beforeAll(async () => {
    // Skip entirely when not in a VM (no live rpcd/ubus).
    // Redirect command -v's stdout (the resolved path) to /dev/null, not just
    // stderr — otherwise stdout is "<path>\nYES" and the === "YES" check below
    // never matches, silently skipping the install and failing every assertion.
    const ubusCheck = await exec(
      "command -v ubus >/dev/null 2>&1 && echo YES || echo NO",
    );
    const rpdCheck = await exec(
      "command -v rpcd >/dev/null 2>&1 && echo YES || echo NO",
    );
    if (
      !IN_VM ||
      ubusCheck.stdout.trim() !== "YES" ||
      rpdCheck.stdout.trim() !== "YES"
    ) {
      return; // tests will be skipped below via skipIf
    }

    // Snapshot /etc/config/singbox-ui for idempotent restore on afterAll
    await exec(`
      _existed=0
      if [ -f /etc/config/singbox-ui ]; then
        cp -f /etc/config/singbox-ui /tmp/sb-prod-uci-snap
        _existed=1
      fi
      echo "$_existed" > /tmp/sb-prod-uci-existed
    `);

    // Install handler + full app tree into real system paths
    await exec(`
      mkdir -p /usr/libexec/rpcd /usr/share/singbox-ui /usr/share/rpcd/acl.d
      cp -f '${HANDLER_SRC}' /usr/libexec/rpcd/singbox-ui
      chmod +x /usr/libexec/rpcd/singbox-ui
      cp -af '${SRC}/usr/share/singbox-ui/.' /usr/share/singbox-ui/
      cp -f '${ACL_SRC}' /usr/share/rpcd/acl.d/luci-singbox-ui.json
    `);

    // Restart rpcd; poll for ubus object (no fixed sleep)
    await exec(`
      /etc/init.d/rpcd restart
      if ubus -t 30 wait_for singbox-ui 2>/dev/null; then
        :
      else
        _deadline=$(( $(date +%s) + 30 ))
        while ! ubus list 2>/dev/null | grep -q '^singbox-ui$'; do
          [ "$(date +%s)" -ge "$_deadline" ] && break
        done
      fi
    `);
  });

  afterAll(async () => {
    if (!IN_VM) return;

    // Restore UCI snapshot
    await exec(`
      _existed=$(cat /tmp/sb-prod-uci-existed 2>/dev/null || echo 0)
      if [ "$_existed" = 1 ]; then
        cp -f /tmp/sb-prod-uci-snap /etc/config/singbox-ui
      else
        rm -f /etc/config/singbox-ui
      fi
      uci -q revert singbox-ui 2>/dev/null || true
      rm -f /tmp/sb-prod-uci-snap /tmp/sb-prod-uci-existed
      # Also clean up any seeded UCI section
      uci -q delete 'singbox-ui.${SEED_NAME}' 2>/dev/null || true
      uci commit singbox-ui 2>/dev/null || true
    `);
  });

  it.skipIf(!IN_VM)("singbox-ui ubus object registered via rpcd", async () => {
    const r = await exec("ubus list 2>/dev/null");
    expect(r.stdout.split("\n")).toContain("singbox-ui");
  });

  it.skipIf(!IN_VM)("1) status via shebang path returns ok", async () => {
    const r = await exec("ubus call singbox-ui status 2>/dev/null");
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain('"status"');
    expect(r.stdout).toMatch(/"status":\s*"ok"/);
    await assertClean("status", r.stdout);
  });

  it.skipIf(!IN_VM)(
    "2) protocol_schema loads lib modules via -L shebang",
    async () => {
      const r = await exec("ubus call singbox-ui protocol_schema 2>/dev/null");
      expect(r.exitCode).toBe(0);
      await assertClean("protocol_schema", r.stdout);
      expect(r.stdout).toMatch(/"status":\s*"ok"/);
      // Must NOT contain a require() failure
      expect(r.stdout).not.toMatch(/require\([^)]+\) failed/);
    },
  );

  it.skipIf(!IN_VM)(
    "3) ubus -v list advertises handler methods via shebang",
    async () => {
      const r = await exec("ubus -v list singbox-ui 2>/dev/null");
      expect(r.exitCode).toBe(0);
      expect(r.stdout).toContain('"status"');
    },
  );

  it.skipIf(!IN_VM)(
    "4a) read_config returns clean JSON envelope via shebang",
    async () => {
      const r = await exec("ubus call singbox-ui read_config 2>/dev/null");
      expect(r.exitCode).toBe(0);
      await assertClean("read_config", r.stdout);
    },
  );

  it.skipIf(!IN_VM)(
    "4c) export_section forks child via shebang (unknown section → clean error)",
    async () => {
      const r = await exec(
        `ubus call singbox-ui export_section '{"kind":"outbound","name":"nonexistent_out"}' 2>/dev/null`,
      );
      expect(r.exitCode).toBe(0);
      await assertClean("export_section", r.stdout);
    },
  );

  it.skipIf(!IN_VM)(
    "4d) CRITIC: export_section returns a RESOLVED section (proves -L require chain)",
    async () => {
      // Seed /etc/config/singbox-ui if absent
      await exec(`
        if [ ! -f /etc/config/singbox-ui ]; then
          cp -f '${SRC}/etc/config/singbox-ui' /etc/config/singbox-ui 2>/dev/null || : > /etc/config/singbox-ui
        fi
        uci -q delete 'singbox-ui.${SEED_NAME}' 2>/dev/null || true
        uci set 'singbox-ui.${SEED_NAME}=inbound'
        uci set 'singbox-ui.${SEED_NAME}.enabled=1'
        uci set 'singbox-ui.${SEED_NAME}.protocol=shadowsocks'
        uci set 'singbox-ui.${SEED_NAME}.listen=::'
        uci set 'singbox-ui.${SEED_NAME}.listen_port=18388'
        uci set 'singbox-ui.${SEED_NAME}.shadowsocks_method=aes-256-gcm'
        uci set 'singbox-ui.${SEED_NAME}.server_password=prodpathsecret'
        uci commit singbox-ui
      `);

      const r = await exec(
        `ubus call singbox-ui export_section '{"kind":"inbound","name":"${SEED_NAME}"}' 2>/dev/null`,
      );

      // Clean up seeded section before asserting
      await exec(
        `uci -q delete 'singbox-ui.${SEED_NAME}' 2>/dev/null; uci commit singbox-ui 2>/dev/null || true`,
      );

      expect(r.exitCode).toBe(0);
      await assertClean("export_section_resolved", r.stdout);
      expect(r.stdout).toMatch(/"status":\s*"ok"/);
      expect(r.stdout).toContain('"type"');
      expect(r.stdout).toMatch(/"type":\s*"shadowsocks"/);
    },
  );
});
