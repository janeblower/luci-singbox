import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

const LIB =
  process.env.SB_VM_LIB ?? "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";
const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const SCRIPT = `${WORK}/singbox-ui/root/usr/share/singbox-ui/nftables.uc`;
const NF_SHARE = `${WORK}/singbox-ui/root/usr/share/singbox-ui`;

// Default emit call: 7893, v4 only, no v6, br-lan
async function emit(): Promise<string> {
  const r = await exec(
    `cd ${WORK} && ucode -L ${LIB} ${SCRIPT} emit 7893 '198.18.0.0/15' '' 'br-lan'`,
  );
  if (r.exitCode !== 0) throw new Error(`emit failed: ${r.stderr}`);
  return r.stdout;
}

async function emitArgs(
  args: string,
): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  return exec(
    `cd ${WORK} && ucode -L ${LIB} ${SCRIPT} emit ${args} 2>/dev/null`,
  );
}

const TMP = `/tmp/sb-nftuc-${process.pid}`;

describe("nftables_uc", () => {
  useGuest();

  beforeAll(async () => {
    await exec(
      `mkdir -p /tmp/singbox-ui ${TMP}/bin-g3 && rm -f /tmp/singbox-ui/rs_uctest_*.json`,
    );
    // create stub nft for G3 tests
    await putFile("#!/bin/sh\nexit 0\n", `${TMP}/bin-g3/nft`);
    await exec(`chmod +x ${TMP}/bin-g3/nft`);
  });

  afterAll(async () => {
    await exec(`rm -f /tmp/singbox-ui/rs_uctest_*.json; rm -rf ${TMP}`);
  });

  it("empty cache: emit succeeds with no rs_ sets", async () => {
    await exec("rm -f /tmp/singbox-ui/rs_uctest_*.json");
    const out = await emit();
    expect(out).toContain("table inet singbox_ui");
    expect(out).not.toContain("set rs_");
  });

  it("scalar ip_cidr: set name, elements, marking rule", async () => {
    await putFile(
      '{ "rules": [ { "ip_cidr": "104.16.0.0/12" } ] }\n',
      "/tmp/singbox-ui/rs_uctest_scalar.json",
    );
    const out = await emit();
    expect(out).toContain("set rs_uctest_scalar_0_v4");
    expect(out).toMatch(/elements = \{ 104\.16\.0\.0\/12 \}/);
    expect(out).toContain(
      "ip daddr @rs_uctest_scalar_0_v4 meta l4proto { tcp, udp } ct state new ct mark set ct mark or 0x40000000",
    );
    await exec("rm /tmp/singbox-ui/rs_uctest_scalar.json");
  });

  it("array ip_cidr mixed v4/v6: splits into two sets", async () => {
    await putFile(
      '{ "rules": [ { "ip_cidr": ["1.2.3.0/24", "fe80::/10", "4.5.0.0/16"] } ] }\n',
      "/tmp/singbox-ui/rs_uctest_mixed.json",
    );
    const out = await emit();
    expect(out).toContain("set rs_uctest_mixed_0_v4");
    expect(out).toContain("set rs_uctest_mixed_0_v6");
    expect(out).toMatch(/elements = \{ 1\.2\.3\.0\/24, ?4\.5\.0\.0\/16 \}/);
    expect(out).toContain("elements = { fe80::/10 }");
    expect(out).toContain("ip6 daddr @rs_uctest_mixed_0_v6");
    await exec("rm /tmp/singbox-ui/rs_uctest_mixed.json");
  });

  it("network=tcp + scalar port_range: produces tcp dport range rule", async () => {
    await putFile(
      '{ "rules": [ { "ip_cidr": "10.0.0.0/8", "network": "tcp", "port_range": "80:443" } ] }\n',
      "/tmp/singbox-ui/rs_uctest_port.json",
    );
    const out = await emit();
    expect(out).toContain(
      "ip daddr @rs_uctest_port_0_v4 meta l4proto tcp tcp dport 80-443 ct state new ct mark set ct mark or 0x40000000",
    );
    await exec("rm /tmp/singbox-ui/rs_uctest_port.json");
  });

  it("network=udp + array port_range: produces udp dport brace set", async () => {
    await putFile(
      '{ "rules": [ { "ip_cidr": "10.0.0.0/8", "network": "udp", "port_range": ["53", "853"] } ] }\n',
      "/tmp/singbox-ui/rs_uctest_ports.json",
    );
    const out = await emit();
    expect(out).toContain("udp dport { 53, 853 }");
    await exec("rm /tmp/singbox-ui/rs_uctest_ports.json");
  });

  it("domain-only rule is skipped; ip_cidr at idx 1 produces rs_..._1_v4", async () => {
    await putFile(
      '{ "rules": [ { "domain_suffix": ["x"] }, { "ip_cidr": "10.0.0.0/8" } ] }\n',
      "/tmp/singbox-ui/rs_uctest_dom.json",
    );
    const out = await emit();
    expect(out).toContain("set rs_uctest_dom_1_v4");
    expect(out).not.toContain("set rs_uctest_dom_0");
    await exec("rm /tmp/singbox-ui/rs_uctest_dom.json");
  });

  it("malformed JSON does not abort run", async () => {
    await putFile("NOT JSON\n", "/tmp/singbox-ui/rs_uctest_bad.json");
    const out = await emit();
    expect(out).toContain("table inet singbox_ui");
    await exec("rm /tmp/singbox-ui/rs_uctest_bad.json");
  });

  it("emitted ruleset has atomic add/delete table prefix", async () => {
    const out = await emit();
    expect(out).toContain("add table inet singbox_ui");
    expect(out).toContain("delete table inet singbox_ui");
  });

  it("long ruleset name is hashed to <= 31 bytes", async () => {
    const longName = "extremelyverylongnamemorethanthirtybytes";
    await putFile(
      '{ "rules": [ { "ip_cidr": "10.0.0.0/8" } ] }\n',
      `/tmp/singbox-ui/rs_${longName}.json`,
    );
    const out = await emit();
    expect(out).toContain("set rs_");
    const setNames = [...out.matchAll(/set (rs_[a-zA-Z0-9_]+)/g)].map(
      (m) => m[1],
    );
    for (const name of setNames) {
      expect(
        name.length,
        `set name '${name}' must be <= 31 chars`,
      ).toBeLessThanOrEqual(31);
    }
    await exec(`rm /tmp/singbox-ui/rs_${longName}.json`);
  });

  it("C2.1.4: invalid listen_port (0, 99999, notaport) produces no tproxy line", async () => {
    for (const port of ["0", "99999", "notaport"]) {
      const r = await emitArgs(`${port} '198.18.0.0/15' '' 'br-lan'`);
      expect(
        r.stdout,
        `port ${port} should not produce tproxy ip`,
      ).not.toContain("tproxy ip to");
    }
  });

  it("C2.1.7: no shell-string nft delete table in emitted script", async () => {
    const out = await emit();
    expect(out).not.toMatch(/"nft".*"delete".*"table"/);
    expect(out).not.toMatch(/system\("nft delete table/);
  });

  it("G6: no shell-invoked mktemp in nftables.uc source", async () => {
    const r = await exec(`grep -q 'popen.*mktemp' ${NF_SHARE}/nftables.uc`);
    expect(r.exitCode, "no popen+mktemp in nftables.uc").not.toBe(0);
  });

  it("G1: malicious fakeip v4 argv injection is rejected", async () => {
    const r = await emitArgs(
      `7893 '198.18.0.0/15 }; insert rule inet filter forward drop; #' '' 'br-lan'`,
    );
    expect(r.stdout).not.toContain("insert rule");
  });

  it("G1: malicious fakeip v6 argv injection is rejected", async () => {
    const r = await emitArgs(
      `7893 '' 'fc00::/7 }; insert rule inet filter forward drop; #' 'br-lan'`,
    );
    expect(r.stdout).not.toContain("insert rule");
  });

  it("G1: clean v4 fakeip range still produces named set and rule", async () => {
    const r = await exec(
      `cd ${WORK} && ucode -L ${LIB} ${SCRIPT} emit 7893 '198.18.0.0/15' '' 'br-lan'`,
    );
    expect(r.exitCode).toBe(0);
    const fakeip4Block = r.stdout
      .split("\n")
      .slice(
        r.stdout
          .split("\n")
          .findIndex((l: string) => l.includes("set fakeip4")),
      )
      .slice(0, 5)
      .join("\n");
    expect(fakeip4Block).toContain("198.18.0.0/15");
    expect(r.stdout).toContain("daddr @fakeip4");
  });

  it("G1: comma-separated CIDR list in v4 arg still works", async () => {
    const r = await exec(
      `cd ${WORK} && ucode -L ${LIB} ${SCRIPT} emit 7893 '192.168.0.0/16,10.0.0.0/8' '' 'br-lan'`,
    );
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("192.168.0.0/16");
    expect(r.stdout).toContain("10.0.0.0/8");
  });

  it("G2: malicious ip_cidr in rs_*.json is dropped (no nft injection)", async () => {
    await putFile(
      '{ "rules": [ { "ip_cidr": ["1.1.1.0/24 }; insert rule inet filter forward drop; #"] } ] }\n',
      "/tmp/singbox-ui/rs_uctest_g2.json",
    );
    const out = await emit();
    expect(out).not.toContain("insert rule");
    await exec("rm /tmp/singbox-ui/rs_uctest_g2.json");
  });

  it("G2: clean ip_cidr elements are preserved", async () => {
    await putFile(
      '{ "rules": [ { "ip_cidr": ["1.1.1.0/24", "8.8.8.8/32"] } ] }\n',
      "/tmp/singbox-ui/rs_uctest_g2clean.json",
    );
    const out = await emit();
    expect(out).toMatch(/elements = \{ 1\.1\.1\.0\/24, ?8\.8\.8\.8\/32 \}/);
    await exec("rm /tmp/singbox-ui/rs_uctest_g2clean.json");
  });

  it("G3: multiple enabled tproxy inbounds produce a warning", async () => {
    const uciDir = `${TMP}/uci-g3-multi`;
    await exec(`mkdir -p ${uciDir}`);
    await putFile(
      `config inbound 'tp1'\n\toption enabled '1'\n\toption protocol 'tproxy'\n\toption listen_port '7893'\nconfig inbound 'tp2'\n\toption enabled '1'\n\toption protocol 'tproxy'\n\toption listen_port '7894'\n`,
      `${uciDir}/singbox-ui`,
    );
    const r = await exec(
      `cd ${WORK} && PATH=${TMP}/bin-g3:$PATH UCI_CONFIG_DIR=${uciDir} ucode -L ${LIB} ${SCRIPT} apply 2>&1 || true`,
    );
    expect(r.stdout + r.stderr).toContain("multiple enabled tproxy");
  });

  it("G3: single enabled tproxy inbound does not warn", async () => {
    const uciDir = `${TMP}/uci-g3-one`;
    await exec(`mkdir -p ${uciDir}`);
    await putFile(
      `config inbound 'tp1'\n\toption enabled '1'\n\toption protocol 'tproxy'\n\toption listen_port '7893'\n`,
      `${uciDir}/singbox-ui`,
    );
    const r = await exec(
      `cd ${WORK} && PATH=${TMP}/bin-g3:$PATH UCI_CONFIG_DIR=${uciDir} ucode -L ${LIB} ${SCRIPT} apply 2>&1 || true`,
    );
    expect(r.stdout + r.stderr).not.toContain("multiple enabled tproxy");
  });

  it("G2b (S1-1): port_range injection is dropped; set still emitted; no dport in rule", async () => {
    await putFile(
      '{ "rules": [ { "ip_cidr": "10.0.0.0/8", "network": "tcp", "port_range": "80 }; insert rule inet filter forward drop; #" } ] }\n',
      "/tmp/singbox-ui/rs_uctest_s11.json",
    );
    const out = await emit();
    expect(out).not.toContain("insert rule");
    expect(out).toContain("set rs_uctest_s11_0_v4");
    const ruleLines = out
      .split("\n")
      .filter((l) => l.includes("@rs_uctest_s11_0_v4"));
    for (const l of ruleLines)
      expect(l, "no dport clause when port dropped").not.toContain("dport");
    await exec("rm /tmp/singbox-ui/rs_uctest_s11.json");
  });
});
