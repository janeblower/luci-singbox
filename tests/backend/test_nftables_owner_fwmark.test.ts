import { afterAll, describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

const LIB =
  process.env.SB_VM_LIB ?? "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";
const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const SCRIPT = `${WORK}/singbox-ui/root/usr/share/singbox-ui/nftables.uc`;

const D = `/tmp/sb-fwmark-test-${process.pid}`;

async function params(configDir: string): Promise<Record<string, unknown>> {
  const r = await exec(
    `cd ${WORK} && UCI_CONFIG_DIR=${configDir} ucode -L ${LIB} ${SCRIPT} params`,
  );
  if (r.exitCode !== 0)
    throw new Error(`params failed: ${r.stderr}\nstdout: ${r.stdout}`);
  return JSON.parse(r.stdout) as Record<string, unknown>;
}

describe("nftables_owner_fwmark", () => {
  useGuest();

  afterAll(async () => {
    await exec(`rm -rf ${D}; rm -f /tmp/singbox-ui/rs_gatetest.json`);
  });

  it("per-inbound fwmark wins over global, mask derived = mark", async () => {
    await exec(`mkdir -p ${D}`);
    await putFile(
      `config inbound 'tp'\n\toption enabled '1'\n\toption protocol 'tproxy'\n\toption listen_port '7895'\n\toption nft_rules '1'\n\toption fwmark '0x123'\nconfig dns_server 'fk'\n\toption enabled '1'\n\toption type 'fakeip'\n\toption inet4_range '198.18.0.0/15'\n`,
      `${D}/singbox-ui`,
    );
    const out = await params(D);
    expect(out.mark).toBe("0x123");
    expect(out.mask).toBe("0x123");
    expect(out.transparent).toBe(1);
    expect(out.v4).toBe("198.18.0.0/15");
  });

  it("no per-inbound fwmark → global fallback", async () => {
    await exec(`mkdir -p ${D}`);
    await putFile(
      `config global 'g'\n\toption fwmark '0x5'\n\toption fwmark_mask '0x5'\nconfig inbound 'tp'\n\toption enabled '1'\n\toption protocol 'tproxy'\n\toption listen_port '7895'\n\toption nft_rules '1'\n`,
      `${D}/singbox-ui`,
    );
    const out = await params(D);
    expect(out.mark).toBe("0x5");
  });

  it("fakeip nft_rules=0 contributes no ranges", async () => {
    await exec(`mkdir -p ${D}`);
    await putFile(
      `config inbound 'tp'\n\toption enabled '1'\n\toption protocol 'tproxy'\n\toption listen_port '7895'\n\toption nft_rules '1'\nconfig dns_server 'fk'\n\toption enabled '1'\n\toption type 'fakeip'\n\toption inet4_range '198.18.0.0/15'\n\toption nft_rules '0'\n`,
      `${D}/singbox-ui`,
    );
    const out = await params(D);
    expect(out.v4).toBe("");
  });

  it("no tproxy nft owner → transparent=0", async () => {
    await exec(`mkdir -p ${D}`);
    await putFile(
      `config inbound 'tp'\n\toption enabled '1'\n\toption protocol 'tproxy'\n\toption listen_port '7895'\n\toption nft_rules '0'\n`,
      `${D}/singbox-ui`,
    );
    const out = await params(D);
    expect(out.transparent).toBe(0);
  });

  it("ruleset present but no tproxy owner → transparent=0 (no-op)", async () => {
    await exec(`mkdir -p ${D} /tmp/singbox-ui`);
    await putFile(
      '{"rules":[{"ip_cidr":["8.8.8.0/24"],"network":"","port_range":[]}]}\n',
      "/tmp/singbox-ui/rs_gatetest.json",
    );
    await putFile(
      `config inbound 'tp'\n\toption enabled '1'\n\toption protocol 'tproxy'\n\toption listen_port '7895'\n\toption nft_rules '0'\nconfig ruleset 'gatetest'\n\toption enabled '1'\n\toption type 'remote'\n\toption nft_rules '1'\n`,
      `${D}/singbox-ui`,
    );
    const out = await params(D);
    expect(out.transparent).toBe(0);
  });
});
