/**
 * tests/cross/test_uci_defaults_migration.test.ts
 * Port of tests/cross/test_uci_defaults_migration.sh
 *
 * Verifies that 99-luci-singbox-ui migrates a range of legacy UCI shapes:
 *   - list inet4_range / inet6_range → scalar option
 *   - tproxy section → inbound + drop expose_*
 *   - DNS model migration (fakeip / dns_outbound / ruleset.dns_fakeip)
 *   - clash_api secret generated + idempotent
 *   - cache legacy enabled=0 + /tmp path → storage=ram
 *   - cache user-customised path (storage=custom)
 *   - cache user-explicit-disable + custom path preserved
 *   - dns_in created for upgrades that don't have it
 *   - dns_in already present is left untouched
 *   - extra_json stripped from inbound/outbound sections
 *   - purge_inbound_mode_json: mode=json → disabled, options absent
 *   - purge_inbound_mode_json: mode=constructor → enabled unchanged, mode absent
 *   - migrate_outbound_type: proxy_type=constructor + protocol → type
 *   - migrate_outbound_type: proxy_type=url/subscription → type=<same>
 *   - migrate_outbound_type + E2 drop: proxy_type=interface → deleted
 *   - migrate_outbound_type: proxy_type=json → disabled, options absent
 *   - S1-7: section enumeration robust to '.'/'=' in option values
 *   - C2.1.2: schema_version sentinel set + idempotent re-run
 *   - C2.1.3: exactly one uci commit in migration script
 *   - C2.1.2: fresh install (no existing config) initialises _meta
 *   - C2.1.2: install already at CURRENT_SCHEMA exits early
 *
 * NOTE: The migration script uses bare `uci` (no -c flag) and stages to
 * /etc/config/singbox-ui directly.  The test guards against an existing file
 * at that path (refuses to clobber a real install).  Requires `uci` — SKIPs
 * on hosts without it (runs for real inside the OpenWrt qemu VM).
 */
import { afterEach, beforeAll, describe, expect, it } from "bun:test";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, unlinkSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

const REPO = resolve(import.meta.dir, "../..");
const SB_BACKEND_ROOT = join(REPO, "singbox-ui/root");
const MIGRATION_SCRIPT = join(
  SB_BACKEND_ROOT,
  "etc/uci-defaults/99-luci-singbox-ui",
);
const REAL_CONFIG = "/etc/config/singbox-ui";

// Check if `uci` is available on this host.
const uciAvailable =
  spawnSync("sh", ["-c", "command -v uci"], { encoding: "utf8" }).status === 0;

// Guard: refuse to run any migration test if the real config already exists.
// (Running in the VM is safe — it always starts without a pre-existing config.)
const configPreExists = existsSync(REAL_CONFIG);
const canRun = uciAvailable && !configPreExists;

// Helper: run the migration script (bare uci, targets /etc/config/singbox-ui).
function runMigration(): {
  status: number | null;
  stdout: string;
  stderr: string;
} {
  return spawnSync("sh", [MIGRATION_SCRIPT], {
    encoding: "utf8",
    env: { ...process.env, IPKG_INSTROOT: "" },
  });
}

// Helper: uci get against the real /etc/config path (used by migration script).
function uciGet(key: string): string {
  const r = spawnSync("uci", ["-q", "get", key], { encoding: "utf8" });
  return (r.stdout ?? "").trim();
}

function uciExists(key: string): boolean {
  return (
    spawnSync("uci", ["-q", "get", key], { encoding: "utf8" }).status === 0
  );
}

function _uciShow(pattern: string): string {
  const r = spawnSync(
    "sh",
    ["-c", `uci -q show singbox-ui | grep '${pattern}'`],
    { encoding: "utf8" },
  );
  return (r.stdout ?? "").trim();
}

// Set up /etc/config directory before any test runs.
beforeAll(() => {
  if (!canRun) return;
  mkdirSync("/etc/config", { recursive: true });
});

// Clean up the config file after each test to keep tests isolated.
afterEach(() => {
  if (existsSync(REAL_CONFIG)) {
    try {
      unlinkSync(REAL_CONFIG);
    } catch {
      /* ignore */
    }
  }
});

describe("test_uci_defaults_migration", () => {
  it.skipIf(!uciAvailable)("migration script exists", () => {
    expect(existsSync(MIGRATION_SCRIPT)).toBe(true);
  });

  it.skipIf(!uciAvailable || configPreExists)(
    "refuses to run if /etc/config/singbox-ui already exists (pre-condition check)",
    () => {
      // This test just validates the test harness precondition.
      expect(configPreExists).toBe(false);
    },
  );

  it.skipIf(!canRun)(
    "inet4_range / inet6_range list → scalar migration",
    () => {
      writeFileSync(
        REAL_CONFIG,
        `config fakeip 'fakeip'
\toption enabled '1'
\tlist inet4_range '198.18.0.0/15'
\tlist inet4_range '198.30.0.0/15'
\tlist inet6_range 'fc00::/18'
`,
        "utf8",
      );

      const r = runMigration();
      expect(r.status, `migration crashed:\n${r.stdout}\n${r.stderr}`).toBe(0);

      const inet4 = uciGet("singbox-ui.fakeip.inet4_range");
      expect(inet4, `inet4_range wrong: ${inet4}`).toBe("198.18.0.0/15");

      const inet6 = uciGet("singbox-ui.fakeip.inet6_range");
      expect(inet6, `inet6_range wrong: ${inet6}`).toBe("fc00::/18");

      // Must now be a scalar (single line in uci show).
      const lines = spawnSync(
        "sh",
        ["-c", "uci show singbox-ui.fakeip | grep -c '\\.inet4_range='"],
        { encoding: "utf8" },
      );
      expect(
        (lines.stdout ?? "").trim(),
        "inet4_range should be scalar (one line)",
      ).toBe("1");
    },
  );

  it.skipIf(!canRun)(
    "tproxy section → inbound migration + drop expose_*",
    () => {
      writeFileSync(
        REAL_CONFIG,
        `config tproxy 'tproxy'
\toption enabled '1'
\tlist interface 'br-lan'
\tlist interface 'br-guest'

config outbound 'p'
\toption proxy_type 'interface'
\toption interface 'eth0'
\toption expose_proxy '1'
\toption expose_type 'socks'
\toption expose_port '1080'
`,
        "utf8",
      );

      const r = runMigration();
      expect(r.status, `migration crashed:\n${r.stdout}\n${r.stderr}`).toBe(0);

      // tproxy section removed.
      expect(
        uciExists("singbox-ui.tproxy"),
        "tproxy section should be deleted",
      ).toBe(false);

      // tproxy_in inbound created with correct interface list.
      const tproxyInType = uciGet("singbox-ui.tproxy_in");
      expect(tproxyInType, "tproxy_in section type != inbound").toBe("inbound");

      const ifaces = spawnSync(
        "sh",
        [
          "-c",
          "uci -q show singbox-ui.tproxy_in.interface | grep -c '\\.interface='",
        ],
        { encoding: "utf8" },
      );
      expect(
        (ifaces.stdout ?? "").trim(),
        "interface should be a single list option line",
      ).toBe("1");
      const ifaceVal = uciGet("singbox-ui.tproxy_in.interface");
      expect(ifaceVal, "interface list missing br-lan").toContain("br-lan");

      // expose_* dropped from outbound.
      expect(
        uciExists("singbox-ui.p.expose_proxy"),
        "expose_proxy should be dropped",
      ).toBe(false);

      // Idempotent rerun.
      const r2 = runMigration();
      expect(r2.status, `rerun crashed:\n${r2.stdout}\n${r2.stderr}`).toBe(0);
      expect(
        uciExists("singbox-ui.tproxy"),
        "rerun resurrected tproxy section",
      ).toBe(false);
    },
  );

  it.skipIf(!canRun)(
    "DNS model migration (fakeip / dns_outbound / ruleset.dns_fakeip)",
    () => {
      writeFileSync(
        REAL_CONFIG,
        `config fakeip 'fakeip'
\toption enabled '1'
\toption inet4_range '198.18.0.0/15'
\toption inet6_range 'fc00::/18'

config dns_outbound 'dns_outbound'
\toption enabled '1'
\toption address 'https://dns.google/dns-query'
\toption detour 'direct'

config ruleset 'ru'
\toption enabled '1'
\toption type 'remote'
\toption url 'https://example.com/ru.srs'
\toption dns_fakeip '1'
\toption dns_fakeip_tag 'fakeip'
`,
        "utf8",
      );

      const r = runMigration();
      expect(r.status, `DNS migration crashed:\n${r.stdout}\n${r.stderr}`).toBe(
        0,
      );

      expect(
        uciGet("singbox-ui.fakeip"),
        "fakeip section type != dns_server",
      ).toBe("dns_server");
      expect(uciGet("singbox-ui.fakeip.type"), "fakeip.type != fakeip").toBe(
        "fakeip",
      );

      expect(
        uciGet("singbox-ui.out_dns.type"),
        "dns_outbound not converted (type)",
      ).toBe("https");
      expect(uciGet("singbox-ui.out_dns.server"), "out_dns.server wrong").toBe(
        "dns.google",
      );
      expect(
        uciGet("singbox-ui.out_dns.path"),
        "out_dns.path != /dns-query",
      ).toBe("/dns-query");
      expect(uciGet("singbox-ui.dns.final"), "dns.final != out_dns").toBe(
        "out_dns",
      );
      expect(
        uciExists("singbox-ui.dns_outbound"),
        "dns_outbound not deleted",
      ).toBe(false);

      expect(
        uciExists("singbox-ui.ru.dns_fakeip"),
        "ruleset.dns_fakeip not removed",
      ).toBe(false);

      // A dns_rule section should have been created pointing to fakeip server.
      const ruleR = spawnSync(
        "sh",
        [
          "-c",
          "uci -q show singbox-ui | sed -n 's/^singbox-ui\\.\\([^.]*\\)=dns_rule$/\\1/p' | head -n1",
        ],
        { encoding: "utf8" },
      );
      const rule = (ruleR.stdout ?? "").trim();
      expect(rule, "no dns_rule created").not.toBe("");
      expect(
        uciGet(`singbox-ui.${rule}.server`),
        "dns_rule.server != fakeip",
      ).toBe("fakeip");

      // Idempotent.
      const r2 = runMigration();
      expect(
        r2.status,
        `DNS migration rerun crashed:\n${r2.stdout}\n${r2.stderr}`,
      ).toBe(0);
      expect(
        uciExists("singbox-ui.dns_outbound"),
        "rerun resurrected dns_outbound",
      ).toBe(false);
    },
  );

  it.skipIf(!canRun)("clash_api secret generated + idempotent", () => {
    writeFileSync(
      REAL_CONFIG,
      `config clash_api 'clash_api'
\toption enabled '0'
\toption listen '127.0.0.1'
\toption port '9090'
`,
      "utf8",
    );

    const r = runMigration();
    expect(r.status, `secret gen crashed:\n${r.stdout}\n${r.stderr}`).toBe(0);

    const sec1 = uciGet("singbox-ui.clash_api.secret");
    expect(sec1, "secret not generated").not.toBe("");

    const r2 = runMigration();
    expect(r2.status, `secret rerun crashed:\n${r2.stdout}\n${r2.stderr}`).toBe(
      0,
    );
    const sec2 = uciGet("singbox-ui.clash_api.secret");
    expect(sec2, `secret changed on rerun (${sec1} → ${sec2})`).toBe(sec1);
  });

  it.skipIf(!canRun)(
    "cache: legacy enabled=0 + /tmp path → storage=ram",
    () => {
      writeFileSync(
        REAL_CONFIG,
        `config cache 'cache'
\toption enabled '0'
\toption path '/tmp/singbox-ui-cache.db'
`,
        "utf8",
      );

      const r = runMigration();
      expect(
        r.status,
        `cache migration crashed:\n${r.stdout}\n${r.stderr}`,
      ).toBe(0);

      expect(
        uciGet("singbox-ui.cache.enabled"),
        "cache enabled not flipped to 1",
      ).toBe("1");
      expect(uciGet("singbox-ui.cache.storage"), "cache storage != ram").toBe(
        "ram",
      );
      expect(
        uciExists("singbox-ui.cache.path"),
        "cache path should be absent after migration",
      ).toBe(false);
      expect(
        uciGet("singbox-ui.cache.store_fakeip"),
        "cache store_fakeip != 1",
      ).toBe("1");
    },
  );

  it.skipIf(!canRun)("cache: user-customised path → storage=custom", () => {
    writeFileSync(
      REAL_CONFIG,
      `config cache 'cache'
\toption enabled '1'
\toption path '/srv/my.db'
`,
      "utf8",
    );

    const r = runMigration();
    expect(
      r.status,
      `cache custom migration crashed:\n${r.stdout}\n${r.stderr}`,
    ).toBe(0);

    expect(uciGet("singbox-ui.cache.storage"), "custom storage != custom").toBe(
      "custom",
    );
    expect(uciGet("singbox-ui.cache.path"), "custom path not preserved").toBe(
      "/srv/my.db",
    );
  });

  it.skipIf(!canRun)(
    "cache: user-explicit-disable + custom path preserved (enabled stays 0)",
    () => {
      writeFileSync(
        REAL_CONFIG,
        `config cache 'cache'
\toption enabled '0'
\toption path '/srv/explicit.db'
`,
        "utf8",
      );

      const r = runMigration();
      expect(
        r.status,
        `explicit-disable migration crashed:\n${r.stdout}\n${r.stderr}`,
      ).toBe(0);

      expect(
        uciGet("singbox-ui.cache.storage"),
        "explicit-disable storage != custom",
      ).toBe("custom");
      expect(
        uciGet("singbox-ui.cache.path"),
        "explicit-disable path not preserved",
      ).toBe("/srv/explicit.db");
      expect(
        uciGet("singbox-ui.cache.enabled"),
        "explicit-disable enabled was flipped (should stay 0)",
      ).toBe("0");
    },
  );

  it.skipIf(!canRun)("dns_in created for upgrades that don't have it", () => {
    writeFileSync(
      REAL_CONFIG,
      `config inbound 'tproxy_in'
\toption enabled '1'
\toption protocol 'tproxy'
\toption listen_port '7893'
`,
      "utf8",
    );

    const r = runMigration();
    expect(r.status, `dns_in creation crashed:\n${r.stdout}\n${r.stderr}`).toBe(
      0,
    );

    expect(uciGet("singbox-ui.dns_in"), "dns_in section type != inbound").toBe(
      "inbound",
    );
    expect(
      uciGet("singbox-ui.dns_in.protocol"),
      "dns_in.protocol != direct",
    ).toBe("direct");
    expect(
      uciGet("singbox-ui.dns_in.listen"),
      "dns_in.listen != 127.0.0.53",
    ).toBe("127.0.0.53");
    expect(
      uciGet("singbox-ui.dns_in.listen_port"),
      "dns_in.listen_port != 53",
    ).toBe("53");
    expect(
      uciGet("singbox-ui.dns_in.dns_listener"),
      "dns_in.dns_listener != 1",
    ).toBe("1");
    expect(uciGet("singbox-ui.dns_in.network"), "dns_in.network != udp").toBe(
      "udp",
    );
    expect(uciGet("singbox-ui.dns_in.enabled"), "dns_in.enabled != 1").toBe(
      "1",
    );
  });

  it.skipIf(!canRun)("dns_in already present is left untouched", () => {
    writeFileSync(
      REAL_CONFIG,
      `config inbound 'dns_in'
\toption enabled '1'
\toption protocol 'direct'
\toption listen '127.0.0.99'
\toption listen_port '53'
\toption dns_listener '1'
`,
      "utf8",
    );

    const r = runMigration();
    expect(r.status, `dns_in preserve crashed:\n${r.stdout}\n${r.stderr}`).toBe(
      0,
    );
    expect(
      uciGet("singbox-ui.dns_in.listen"),
      "dns_in.listen was overwritten (expected 127.0.0.99)",
    ).toBe("127.0.0.99");
  });

  it.skipIf(!canRun)(
    "extra_json stripped from inbound/outbound sections",
    () => {
      writeFileSync(
        REAL_CONFIG,
        `config inbound 'a'
\toption protocol 'tproxy'
\toption extra_json '{"sniff":true}'

config outbound 'b'
\toption proxy_type 'constructor'
\toption protocol 'vless'
\toption extra_json '{"x":1}'
`,
        "utf8",
      );

      const r = runMigration();
      expect(
        r.status,
        `purge_extra_json crashed:\n${r.stdout}\n${r.stderr}`,
      ).toBe(0);
      expect(
        uciExists("singbox-ui.a.extra_json"),
        "extra_json should be absent from inbound 'a'",
      ).toBe(false);
      expect(
        uciExists("singbox-ui.b.extra_json"),
        "extra_json should be absent from outbound 'b'",
      ).toBe(false);
    },
  );

  it.skipIf(!canRun)(
    "purge_inbound_mode_json: mode=json → disabled, options absent",
    () => {
      writeFileSync(
        REAL_CONFIG,
        `config inbound 'ib_json'
\toption enabled '1'
\toption protocol 'vless'
\toption mode 'json'
\toption inbound_json '{"type":"vless","tag":"vless-in","listen":"::","listen_port":1080}'
`,
        "utf8",
      );

      const r = runMigration();
      expect(
        r.status,
        `purge_inbound_mode_json (json) crashed:\n${r.stdout}\n${r.stderr}`,
      ).toBe(0);
      expect(
        uciGet("singbox-ui.ib_json.enabled"),
        "mode=json inbound should be disabled after migration",
      ).toBe("0");
      expect(
        uciExists("singbox-ui.ib_json.mode"),
        "mode option should be absent after migration",
      ).toBe(false);
      expect(
        uciExists("singbox-ui.ib_json.inbound_json"),
        "inbound_json option should be absent after migration",
      ).toBe(false);
    },
  );

  it.skipIf(!canRun)(
    "purge_inbound_mode_json: mode=constructor → enabled unchanged, mode absent",
    () => {
      writeFileSync(
        REAL_CONFIG,
        `config inbound 'ib_ctor'
\toption enabled '1'
\toption protocol 'tproxy'
\toption mode 'constructor'
\toption listen_port '7893'
`,
        "utf8",
      );

      const r = runMigration();
      expect(
        r.status,
        `purge_inbound_mode_json (constructor) crashed:\n${r.stdout}\n${r.stderr}`,
      ).toBe(0);
      expect(
        uciGet("singbox-ui.ib_ctor.enabled"),
        "mode=constructor inbound enabled should stay 1",
      ).toBe("1");
      expect(
        uciExists("singbox-ui.ib_ctor.mode"),
        "mode option should be absent after migration",
      ).toBe(false);
    },
  );

  it.skipIf(!canRun)(
    "migrate_outbound_type: proxy_type=constructor + protocol=vless → type=vless",
    () => {
      writeFileSync(
        REAL_CONFIG,
        `config outbound 'ob_ctor'
\toption enabled '1'
\toption proxy_type 'constructor'
\toption protocol 'vless'
\toption server 'v.example.com'
\toption server_port '443'
`,
        "utf8",
      );

      const r = runMigration();
      expect(
        r.status,
        `migrate_outbound_type (constructor+vless) crashed:\n${r.stdout}\n${r.stderr}`,
      ).toBe(0);
      expect(
        uciGet("singbox-ui.ob_ctor.type"),
        "expected type=vless after migration",
      ).toBe("vless");
      expect(
        uciExists("singbox-ui.ob_ctor.proxy_type"),
        "proxy_type should be absent after migration",
      ).toBe(false);
      expect(
        uciExists("singbox-ui.ob_ctor.protocol"),
        "protocol should be absent after migration",
      ).toBe(false);
    },
  );

  for (const pt of ["url", "subscription"]) {
    const _pt = pt;
    it.skipIf(!canRun)(
      `migrate_outbound_type: proxy_type=${_pt} → type=${_pt}`,
      () => {
        writeFileSync(
          REAL_CONFIG,
          `config outbound 'ob_${_pt}'
\toption enabled '1'
\toption proxy_type '${_pt}'
`,
          "utf8",
        );

        const r = runMigration();
        expect(
          r.status,
          `migrate_outbound_type (${_pt}) crashed:\n${r.stdout}\n${r.stderr}`,
        ).toBe(0);
        expect(
          uciGet(`singbox-ui.ob_${_pt}.type`),
          `expected type=${_pt}`,
        ).toBe(_pt);
        expect(
          uciExists(`singbox-ui.ob_${_pt}.proxy_type`),
          `proxy_type should be absent (${_pt})`,
        ).toBe(false);
      },
    );
  }

  it.skipIf(!canRun)(
    "migrate_outbound_type + E2 drop: proxy_type=interface → deleted",
    () => {
      writeFileSync(
        REAL_CONFIG,
        `config outbound 'ob_interface'
\toption enabled '1'
\toption proxy_type 'interface'
`,
        "utf8",
      );

      const r = runMigration();
      expect(
        r.status,
        `migrate (interface) crashed:\n${r.stdout}\n${r.stderr}`,
      ).toBe(0);
      expect(
        uciExists("singbox-ui.ob_interface"),
        "ob_interface should be deleted by E2 Migration B",
      ).toBe(false);
    },
  );

  it.skipIf(!canRun)(
    "migrate_outbound_type: proxy_type=json → disabled, options absent",
    () => {
      writeFileSync(
        REAL_CONFIG,
        `config outbound 'ob_json'
\toption enabled '1'
\toption proxy_type 'json'
\toption proxy_json '{"type":"vless","tag":"x"}'
`,
        "utf8",
      );

      const r = runMigration();
      expect(
        r.status,
        `migrate_outbound_type (json) crashed:\n${r.stdout}\n${r.stderr}`,
      ).toBe(0);
      expect(
        uciGet("singbox-ui.ob_json.enabled"),
        "proxy_type=json outbound should be disabled after migration",
      ).toBe("0");
      expect(
        uciExists("singbox-ui.ob_json.proxy_type"),
        "proxy_type should be absent after migration",
      ).toBe(false);
      expect(
        uciExists("singbox-ui.ob_json.proxy_json"),
        "proxy_json should be absent after migration",
      ).toBe(false);
    },
  );

  it.skipIf(!canRun)(
    "S1-7: section enumeration robust to '.'/'=' in option values",
    () => {
      writeFileSync(
        REAL_CONFIG,
        `config inbound 'edge_in'
\toption enabled '1'
\toption protocol 'tproxy'
\toption transport 'ws'
\toption server_password 'a=b.c=d'
`,
        "utf8",
      );

      const r = runMigration();
      expect(
        r.status,
        `S1-7 migration crashed:\n${r.stdout}\n${r.stderr}`,
      ).toBe(0);
      expect(
        uciGet("singbox-ui.edge_in.transport_type"),
        "S1-7 transport not renamed",
      ).toBe("ws");
      expect(
        uciExists("singbox-ui.edge_in.transport"),
        "S1-7 old transport key not removed",
      ).toBe(false);
      expect(
        uciGet("singbox-ui.edge_in.server_password"),
        "S1-7 sibling option value mangled",
      ).toBe("a=b.c=d");
    },
  );

  it.skipIf(!canRun)(
    "C2.1.3: exactly one uci commit singbox-ui in migration script",
    () => {
      const r = spawnSync(
        "sh",
        [
          "-c",
          `grep -Ec '^[[:space:]]*uci[[:space:]]+(-q[[:space:]]+)?commit[[:space:]]+singbox-ui' "${MIGRATION_SCRIPT}"`,
        ],
        { encoding: "utf8" },
      );
      const count = parseInt((r.stdout ?? "").trim(), 10);
      expect(
        count,
        `expected exactly 1 'uci commit singbox-ui', got ${count}`,
      ).toBe(1);
    },
  );

  it.skipIf(!canRun)(
    "C2.1.2: fresh install initialises _meta.schema_version",
    () => {
      writeFileSync(REAL_CONFIG, "", "utf8"); // empty config = fresh install

      const r = runMigration();
      expect(
        r.status,
        `fresh-install migration crashed:\n${r.stdout}\n${r.stderr}`,
      ).toBe(0);

      const ver = parseInt(
        uciGet("singbox-ui._meta.schema_version") || "0",
        10,
      );
      expect(
        ver,
        `fresh install did not set _meta.schema_version (got '${ver}')`,
      ).toBeGreaterThanOrEqual(1);
    },
  );

  it.skipIf(!canRun)(
    "C2.1.2: schema_version sentinel set + idempotent re-run",
    () => {
      // Run a fresh migration to get a valid schema_version.
      writeFileSync(REAL_CONFIG, "", "utf8");
      const r1 = runMigration();
      expect(
        r1.status,
        `first migration crashed:\n${r1.stdout}\n${r1.stderr}`,
      ).toBe(0);

      const ver = uciGet("singbox-ui._meta.schema_version");
      expect(
        parseInt(ver || "0", 10),
        `_meta.schema_version not set (got '${ver}')`,
      ).toBeGreaterThanOrEqual(1);

      const r2 = runMigration();
      expect(r2.status, `re-run crashed:\n${r2.stdout}\n${r2.stderr}`).toBe(0);
      const ver2 = uciGet("singbox-ui._meta.schema_version");
      expect(ver2, `schema_version drifted on re-run: ${ver} -> ${ver2}`).toBe(
        ver,
      );
    },
  );

  it.skipIf(!canRun)(
    "C2.1.2: install at-or-above CURRENT_SCHEMA exits early (no migration fires)",
    () => {
      // Seed schema_version=999 (well above any real CURRENT_SCHEMA).
      writeFileSync(
        REAL_CONFIG,
        `config _meta '_meta'
\toption schema_version '999'

config fakeip 'fakeip'
\toption enabled '1'
\tlist inet4_range '198.18.0.0/15'
\tlist inet4_range '198.30.0.0/15'
`,
        "utf8",
      );

      const r = runMigration();
      expect(
        r.status,
        `future-schema rerun crashed:\n${r.stdout}\n${r.stderr}`,
      ).toBe(0);

      // fakeip must NOT have been migrated (early-exit fired).
      const secType = uciGet("singbox-ui.fakeip");
      expect(
        secType,
        `early-exit failed — fakeip section type is '${secType}' (expected 'fakeip')`,
      ).toBe("fakeip");

      const verKept = uciGet("singbox-ui._meta.schema_version");
      expect(
        verKept,
        `schema_version was rewritten from 999 to '${verKept}'`,
      ).toBe("999");
    },
  );
});
