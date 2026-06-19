import { afterAll, describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

const LIB =
  process.env.SB_VM_LIB ?? "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";
const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const BASELINE = `${WORK}/tests/fixtures/build_ruleset/nftables.baseline.uc`;
const SCRIPT = `${WORK}/singbox-ui/root/usr/share/singbox-ui/nftables.uc`;
const RS = "/tmp/singbox-ui";

async function emitFrom(script: string, args: string): Promise<string> {
  const r = await exec(`cd ${WORK} && ucode -L ${LIB} ${script} emit ${args}`);
  if (r.exitCode !== 0) throw new Error(`emit failed: ${r.stderr}`);
  return r.stdout;
}

async function check(label: string, args: string): Promise<void> {
  const [want, got] = await Promise.all([
    emitFrom(BASELINE, args),
    emitFrom(SCRIPT, args),
  ]);
  expect(got, `${label}: byte-identical`).toBe(want);
}

describe("nftables_build_ruleset_char", () => {
  useGuest();

  afterAll(async () => {
    await exec(`rm -f ${RS}/rs_char_*.json`);
  });

  it("baseline and script exist", async () => {
    const r1 = await exec(`test -f ${BASELINE}`);
    expect(r1.exitCode, "baseline fixture exists").toBe(0);
    const r2 = await exec(`test -x ${SCRIPT}`);
    expect(r2.exitCode, "current script is executable").toBe(0);
  });

  it("m_fakeip_v4_only: byte-identical", async () => {
    await check("m_fakeip_v4_only", `7893 "198.18.0.0/15" "" "br-lan" 0x1 0x1`);
  });

  it("m_fakeip_v4_v6: byte-identical", async () => {
    await check(
      "m_fakeip_v4_v6",
      `7895 "198.18.0.0/15" "fc00::/18" "br-lan" 0x1 0x1`,
    );
  });

  it("m_router_out_on: byte-identical", async () => {
    await check(
      "m_router_out_on",
      `7895 "198.18.0.0/15" "fc00::/18" "br-lan" 0x1 0x1 1`,
    );
  });

  it("m_multi_iface: byte-identical", async () => {
    await check(
      "m_multi_iface",
      `7893 "198.18.0.0/15" "" "br-lan,br-guest" 0x1 0x1`,
    );
  });

  it("m_port_empty_skip: byte-identical", async () => {
    await check(
      "m_port_empty_skip",
      `"" "198.18.0.0/15" "fc00::/18" "br-lan" 0x1 0x1`,
    );
  });

  it("m_mark_ne_mask_rout: byte-identical", async () => {
    await check(
      "m_mark_ne_mask_rout",
      `7895 "198.18.0.0/15" "fc00::/18" "br-lan" 0x40 0xc0 1`,
    );
  });

  it("m_with_ruleset: byte-identical (rs_* set)", async () => {
    await exec(`mkdir -p ${RS}`);
    await putFile(
      '{ "rules": [ { "ip_cidr": ["1.2.3.0/24","fe80::/10"], "network":"tcp" } ] }\n',
      `${RS}/rs_char_set.json`,
    );
    await check(
      "m_with_ruleset",
      `7893 "198.18.0.0/15" "fc00::/18" "br-lan" 0x1 0x1`,
    );
  });

  it("m_with_ruleset_rout: byte-identical (rs_* set + router_out)", async () => {
    // rs_char_set.json already placed by previous test; if running isolated, place it again
    await exec(`mkdir -p ${RS}`);
    await putFile(
      '{ "rules": [ { "ip_cidr": ["1.2.3.0/24","fe80::/10"], "network":"tcp" } ] }\n',
      `${RS}/rs_char_set.json`,
    );
    await check(
      "m_with_ruleset_rout",
      `7893 "198.18.0.0/15" "fc00::/18" "br-lan" 0x1 0x1 1`,
    );
  });
});
