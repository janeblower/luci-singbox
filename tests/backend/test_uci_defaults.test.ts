import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec } from "../helpers/ssh.ts";

// 99-luci-singbox-ui is what runs on EVERY fresh install and every upgrade, and
// until now nothing exercised it: its tests lived in tests/cross gated on
// `command -v uci`, and the cross project runs on ubuntu-24.04 where uci does
// not exist — 31 tests, permanently skipped, permanently green. That is how the
// script came to delete the seeded `tun_in` on first boot (and live vmess/tuic/
// anytls/ssh outbounds on upgrade) without anyone noticing.
//
// So it lives here, in the lane with a real uci: the guest. The script takes the
// same SINGBOX_UCI seam as seed-rulesets.sh because the uci CLI does NOT honour
// UCI_CONFIG_DIR (only `-c <dir>`), so without it this could only be run against
// the live /etc/config.

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const SCRIPT = `${WORK}/singbox-ui/root/etc/uci-defaults/99-luci-singbox-ui`;
const SHIPPED = `${WORK}/singbox-ui/root/etc/config/singbox-ui`;
const CURRENT_SCHEMA = "19";

async function run(dir: string): Promise<number> {
  const r = await exec(
    `SINGBOX_UCI="uci -c ${dir}" sh ${SCRIPT}; echo "rc=$?"`,
  );
  const m = r.stdout.match(/rc=(\d+)/);
  return m ? Number(m[1]) : -1;
}

// "singbox-ui.foo.bar=baz" -> { "foo.bar": "baz", foo: "<type>" }
async function dump(dir: string): Promise<Record<string, string>> {
  const r = await exec(`uci -c ${dir} show singbox-ui 2>/dev/null || true`);
  const out: Record<string, string> = {};
  for (const line of r.stdout.split("\n")) {
    const m = line.match(/^singbox-ui\.([^.=]+)(?:\.([^=]+))?=(.*)$/);
    if (!m) continue;
    const [, sec, opt, val] = m;
    out[opt ? `${sec}.${opt}` : sec] = val.replace(/^'|'$/g, "");
  }
  return out;
}

async function seed(dir: string, config: string | null): Promise<void> {
  await exec(`rm -rf ${dir} && mkdir -p ${dir}`);
  if (config === null) return; // fresh box, no config file at all
  if (config === "shipped") {
    await exec(`cp ${SHIPPED} ${dir}/singbox-ui`);
    return;
  }
  await exec(`cat > ${dir}/singbox-ui <<'SBEOF'\n${config}\nSBEOF`);
}

describe("99-luci-singbox-ui", () => {
  useGuest();

  const DIR = `/tmp/sb-migr-${process.pid}`;

  it("a fresh install keeps everything the seed shipped", async () => {
    // THE regression. The shipped config carries no _meta, so cur_ver=0 and the
    // whole ladder used to run — including migrate_drop_removed_protocols, which
    // deleted every inbound with protocol=tun. First boot, and the seeded tun_in
    // was gone.
    await seed(DIR, "shipped");
    expect(await run(DIR)).toBe(0);

    const u = await dump(DIR);
    expect(u.tun_in).toBe("inbound");
    expect(u["tun_in.protocol"]).toBe("tun");
    expect(u.tproxy_in).toBe("inbound");
    expect(u.dns_in).toBe("inbound");
    expect(u["_meta.schema_version"]).toBe(CURRENT_SCHEMA);
  });

  it("re-running on an already-migrated box is an early exit", async () => {
    const before = await dump(DIR);
    expect(await run(DIR)).toBe(0);
    expect(await dump(DIR)).toEqual(before);
  });

  it("ships the fwmark defaults as a real config section", async () => {
    // These used to be written by a separate uci-defaults script (90-*-fwmark)
    // that seeded the exact values the backend already falls back to, then
    // deleted itself. They are in etc/config now.
    const u = await dump(DIR);
    expect(u["@global[0].fwmark"]).toBe("0x40000000");
    expect(u["@global[0].fwmark_mask"]).toBe("0x40000000");
    expect(u["@global[0].redirect_router_traffic"]).toBe("0");
  });

  it("an upgrade keeps outbounds whose protocol came back", async () => {
    // vmess/tuic/anytls/ssh all have descriptors again and are all in the
    // outbound dropdown. The drop-list had rotted in the other direction and was
    // deleting live user config on every upgrade from schema <19. `interface` is
    // the only type that never came back — and nothing writes it any more.
    await seed(
      DIR,
      [
        "config outbound 'v'",
        "\toption type 'vmess'",
        "",
        "config outbound 't'",
        "\toption type 'tuic'",
        "",
        "config outbound 'a'",
        "\toption type 'anytls'",
        "",
        "config outbound 's'",
        "\toption type 'ssh'",
        "",
        "config inbound 'mytun'",
        "\toption protocol 'tun'",
      ].join("\n"),
    );
    expect(await run(DIR)).toBe(0);

    const u = await dump(DIR);
    expect(u.v).toBe("outbound");
    expect(u.t).toBe("outbound");
    expect(u.a).toBe("outbound");
    expect(u.s).toBe("outbound");
    expect(u.mytun).toBe("inbound");
  });

  it("renames the pre-E2 keys no descriptor can read", async () => {
    // The one migration that must NOT be dropped: a box on schema 15 holds
    // security/transport/utls_fingerprint, and losing them means losing TLS and
    // the transport silently.
    await seed(
      DIR,
      [
        "config outbound 'o'",
        "\toption type 'vless'",
        "\toption security 'reality'",
        "\toption transport 'httpupgrade'",
        "\toption transport_host 'example.com'",
        "\toption utls_fingerprint 'chrome'",
        "\toption tls_ech '1'",
      ].join("\n"),
    );
    expect(await run(DIR)).toBe(0);

    const u = await dump(DIR);
    expect(u["o.tls_enabled"]).toBe("1");
    expect(u["o.reality_enabled"]).toBe("1");
    expect(u["o.security"]).toBeUndefined();
    expect(u["o.transport_type"]).toBe("httpupgrade");
    expect(u["o.transport_host_httpupgrade"]).toBe("example.com");
    expect(u["o.transport"]).toBeUndefined();
    expect(u["o.transport_host"]).toBeUndefined();
    expect(u["o.utls_enabled"]).toBe("1");
    expect(u["o.utls_fingerprint"]).toBe("chrome");
    expect(u["o.tls_ech_enabled"]).toBe("1");
    expect(u["o.tls_ech"]).toBeUndefined();
  });

  it("creates the sections an upgrade may be missing, with a secret", async () => {
    await seed(DIR, "config singbox-ui 'main'\n\toption default_rulesets '1'");
    expect(await run(DIR)).toBe(0);

    const u = await dump(DIR);
    expect(u.log).toBe("log");
    expect(u.cache).toBe("cache");
    expect(u["cache.storage"]).toBe("ram");
    expect(u.plugins).toBe("singbox-ui");
    expect(u.clash_api).toBe("clash_api");
    expect(u["clash_api.secret"]).toMatch(/^\S+$/);
    expect(u.dns_in).toBe("inbound");
    expect(u["dns_in.dns_listener"]).toBe("1");
  });

  it("never touches a dns_in the user already customised", async () => {
    await seed(
      DIR,
      "config inbound 'dns_in'\n\toption enabled '0'\n\toption listen_port '5353'",
    );
    expect(await run(DIR)).toBe(0);

    const u = await dump(DIR);
    expect(u["dns_in.enabled"]).toBe("0");
    expect(u["dns_in.listen_port"]).toBe("5353");
  });

  it("commits exactly once", async () => {
    // Every migration is an in-memory edit and the single trailing commit is the
    // only point UCI files are rewritten — crash-safe between steps.
    const r = await exec(`grep -c '^uci_ commit' ${SCRIPT}`);
    expect(r.stdout.trim()).toBe("1");
  });
});
