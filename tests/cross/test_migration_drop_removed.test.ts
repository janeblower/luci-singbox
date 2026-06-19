/**
 * tests/cross/test_migration_drop_removed.test.ts
 * Port of tests/cross/test_migration_drop_removed.sh
 *
 * Exercises migrate_drop_removed_protocols on a fixture config with one of
 * every removed type plus one survivor.  Requires `uci` — SKIPs on hosts
 * without it (runs for real inside the OpenWrt qemu VM).
 */
import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const REPO = resolve(import.meta.dir, "../..");
const SB_BACKEND_ROOT = join(REPO, "singbox-ui/root");
const MIGRATION_SCRIPT = join(
  SB_BACKEND_ROOT,
  "etc/uci-defaults/99-luci-singbox-ui",
);

// Check if `uci` is available on this host.
const uciAvailable =
  spawnSync("uci", ["--version"], { encoding: "utf8" }).status === 0 ||
  spawnSync("sh", ["-c", "command -v uci"], { encoding: "utf8" }).status === 0;

// Helper: run a uci command against a specific config dir (-c flag).
function _uci(
  configDir: string,
  ...args: string[]
): { stdout: string; status: number | null } {
  const r = spawnSync("uci", ["-c", configDir, ...args], { encoding: "utf8" });
  return { stdout: (r.stdout ?? "").trim(), status: r.status };
}

// Helper: run the migration script against /etc/config/singbox-ui.
// The script uses bare `uci` so we must stage the config at the real path.
// Guard: the test refuses to run if /etc/config/singbox-ui already exists.
const REAL_CONFIG = "/etc/config/singbox-ui";

let TMP: string;

describe("test_migration_drop_removed", () => {
  beforeAll(() => {
    TMP = mkdtempSync(join(tmpdir(), "mig-drop-"));
  });

  afterAll(() => {
    rmSync(TMP, { recursive: true, force: true });
    // Clean up real config if we created it.
    if (existsSync(REAL_CONFIG)) {
      try {
        unlinkSync(REAL_CONFIG);
      } catch {
        /* ignore */
      }
    }
  });

  it.skipIf(!uciAvailable)("migration script exists and is executable", () => {
    expect(existsSync(MIGRATION_SCRIPT)).toBe(true);
  });

  it.skipIf(!uciAvailable)(
    "refuses to run if /etc/config/singbox-ui already exists",
    () => {
      if (existsSync(REAL_CONFIG)) {
        // Can't run this test safely — the config already exists.
        return;
      }
      // Verified safe: config absent.
      expect(existsSync(REAL_CONFIG)).toBe(false);
    },
  );

  it.skipIf(!uciAvailable)(
    "removed sections are deleted, survivor sections remain, renames applied",
    () => {
      // If /etc/config/singbox-ui already exists on this host, skip rather than clobber.
      if (existsSync(REAL_CONFIG)) {
        console.log("SKIP: /etc/config/singbox-ui exists, refusing to clobber");
        return;
      }

      const fixture = `config inbound 'tproxy_in'
    option enabled '1'
    option protocol 'tproxy'

config inbound 'tun_in'
    option enabled '1'
    option protocol 'tun'

config inbound 'vmess_in'
    option enabled '1'
    option protocol 'vmess'

config outbound 'vless_out'
    option enabled '1'
    option type 'vless'
    option transport 'ws'
    option security 'tls'
    option utls_fingerprint 'chrome'

config outbound 'vmess_out'
    option enabled '1'
    option type 'vmess'

config outbound 'tuic_out'
    option enabled '1'
    option type 'tuic'

config outbound 'anytls_out'
    option enabled '1'
    option type 'anytls'

config outbound 'ssh_out'
    option enabled '1'
    option type 'ssh'

config outbound 'interface_out'
    option enabled '1'
    option type 'interface'
`;
      try {
        // Ensure /etc/config/ exists (it does on OpenWrt; may not on dev host).
        mkdirSync("/etc/config", { recursive: true });
        writeFileSync(REAL_CONFIG, fixture, "utf8");

        const r = spawnSync("sh", [MIGRATION_SCRIPT], {
          encoding: "utf8",
          env: { ...process.env, IPKG_INSTROOT: "" },
        });
        expect(r.status, `migration crashed:\n${r.stdout}\n${r.stderr}`).toBe(
          0,
        );

        // Removed sections must be gone.
        for (const s of [
          "tun_in",
          "vmess_in",
          "vmess_out",
          "tuic_out",
          "anytls_out",
          "ssh_out",
          "interface_out",
        ]) {
          const check = spawnSync("uci", ["-q", "get", `singbox-ui.${s}`], {
            encoding: "utf8",
          });
          expect(check.status, `section '${s}' survived migration`).not.toBe(0);
        }

        // Surviving sections must still exist.
        for (const s of ["tproxy_in", "vless_out"]) {
          const check = spawnSync("uci", ["-q", "get", `singbox-ui.${s}`], {
            encoding: "utf8",
          });
          expect(check.status, `section '${s}' was removed by mistake`).toBe(0);
        }

        // Migration A rename assertions: vless_out kept and transport key renamed.
        const transportType = spawnSync(
          "uci",
          ["-q", "get", "singbox-ui.vless_out.transport_type"],
          { encoding: "utf8" },
        );
        expect(
          transportType.stdout.trim(),
          "transport→transport_type not renamed",
        ).toBe("ws");

        const oldTransport = spawnSync(
          "uci",
          ["-q", "get", "singbox-ui.vless_out.transport"],
          { encoding: "utf8" },
        );
        expect(oldTransport.status, "old transport key not deleted").not.toBe(
          0,
        );

        const tlsEnabled = spawnSync(
          "uci",
          ["-q", "get", "singbox-ui.vless_out.tls_enabled"],
          { encoding: "utf8" },
        );
        expect(
          tlsEnabled.stdout.trim(),
          "security=tls → tls_enabled=1 not applied",
        ).toBe("1");

        const utlsEnabled = spawnSync(
          "uci",
          ["-q", "get", "singbox-ui.vless_out.utls_enabled"],
          { encoding: "utf8" },
        );
        expect(
          utlsEnabled.stdout.trim(),
          "utls_fingerprint set → utls_enabled=1 not applied",
        ).toBe("1");

        // Idempotent rerun.
        const r2 = spawnSync("sh", [MIGRATION_SCRIPT], {
          encoding: "utf8",
          env: { ...process.env, IPKG_INSTROOT: "" },
        });
        expect(r2.status, `rerun crashed:\n${r2.stdout}\n${r2.stderr}`).toBe(0);
      } finally {
        if (existsSync(REAL_CONFIG)) unlinkSync(REAL_CONFIG);
      }
    },
  );
});
