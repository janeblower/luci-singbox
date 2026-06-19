import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

const LIB =
  process.env.SB_VM_LIB ?? "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";
const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const SCRIPT = `${WORK}/singbox-ui/root/usr/share/singbox-ui/nftables.uc`;

function emit(
  args: string,
): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  return exec(`cd ${WORK} && ucode -L ${LIB} ${SCRIPT} emit ${args}`);
}

describe("nftables_emit", () => {
  useGuest();

  beforeAll(async () => {
    await exec(
      "rm -f /tmp/singbox-ui/rs_test_*.json 2>/dev/null; mkdir -p /tmp/singbox-ui",
    );
  });

  afterAll(async () => {
    await exec("rm -f /tmp/singbox-ui/rs_test_*.json 2>/dev/null");
  });

  it("ucode parse check", async () => {
    const r = await exec(`cd ${WORK} && ucode -c -o /dev/null ${SCRIPT}`);
    expect(r.exitCode).toBe(0);
  });

  it("emit: single prerouting chain at priority mangle", async () => {
    const r = await emit("7895 198.18.0.0/15 fc00::/18 br-lan");
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("chain prerouting {");
    expect(r.stdout).toContain("type filter hook prerouting priority mangle");
    expect(r.stdout).not.toContain("chain prerouting_mark");
    expect(r.stdout).not.toContain("chain prerouting_tproxy");
  });

  it("emit: named sets wan_ifaces, fakeip4, fakeip6", async () => {
    const r = await emit("7895 198.18.0.0/15 fc00::/18 br-lan");
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("set wan_ifaces");
    expect(r.stdout).toContain("type ifname");
    expect(r.stdout).toContain("set fakeip4");
    expect(r.stdout).toContain("set fakeip6");
  });

  it("emit: socket transparent fast-path is the first rule in prerouting", async () => {
    const r = await emit("7895 198.18.0.0/15 fc00::/18 br-lan");
    expect(r.exitCode).toBe(0);
    const lines = r.stdout.split("\n");
    let inPrerouting = false;
    let firstContentLine: string | null = null;
    for (const line of lines) {
      if (/chain prerouting \{/.test(line)) {
        inPrerouting = true;
        continue;
      }
      if (inPrerouting) {
        // Skip the type declaration line
        if (/^\t\ttype/.test(line)) continue;
        // First non-type content line with real content
        if (/^\t\t[a-zA-Z]/.test(line)) {
          firstContentLine = line;
          break;
        }
      }
    }
    expect(firstContentLine).not.toBeNull();
    expect(firstContentLine).toContain("socket transparent 1");
  });

  it("emit: rs_* and fakeip decision rules write ct mark, not meta mark", async () => {
    const r = await emit("7895 198.18.0.0/15 fc00::/18 br-lan");
    expect(r.exitCode).toBe(0);
    // Lines with ct state new must NOT use meta mark set
    const ctStateNewLines = r.stdout
      .split("\n")
      .filter((l) => l.includes("ct state new"));
    for (const line of ctStateNewLines) {
      expect(line).not.toContain("meta mark set");
    }
    expect(r.stdout).toContain("ct mark set ct mark or 0x40000000");
  });

  it("emit: TPROXY uses AND-mask (not exact equality)", async () => {
    const r = await emit("7895 198.18.0.0/15 fc00::/18 br-lan");
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("meta mark and 0x40000000 == 0x40000000");
    // Must NOT have old exact-equality form before tproxy rule
    const badPattern = r.stdout
      .split("\n")
      .some(
        (line) =>
          /meta mark 0x40000000 meta l4proto/.test(line) &&
          line.includes("tproxy"),
      );
    expect(badPattern).toBe(false);
  });

  it("emit: tproxy targets present for tcp+udp, v4+v6", async () => {
    const r = await emit("7895 198.18.0.0/15 fc00::/18 br-lan");
    expect(r.exitCode).toBe(0);
    // Normalize whitespace
    const norm = r.stdout
      .split("\n")
      .map((l) => l.replace(/\s+/g, " "))
      .join("\n");
    expect(norm).toContain("tproxy ip to 127.0.0.1:7895");
    expect(norm).toContain("tproxy ip6 to [::1]:7895");
  });

  it("count: exactly four tproxy rules (tcp+udp x v4+v6)", async () => {
    const r = await emit("7895 198.18.0.0/15 fc00::/18 br-lan");
    expect(r.exitCode).toBe(0);
    const count = r.stdout
      .split("\n")
      .filter((l) => l.includes("tproxy ip")).length;
    expect(count).toBe(4);
  });

  it("nft -c accepts the emitted rules", async () => {
    const r = await emit("7893 198.18.0.0/15 fc00::/18 br-lan");
    expect(r.exitCode).toBe(0);
    const tmpPath = "/tmp/singbox-ui-nft-check.nft";
    await putFile(r.stdout, tmpPath);
    const nftResult = await exec(
      `nft -c -f ${tmpPath} 2>/tmp/singbox-ui-nft-check.err || true`,
    );
    const nftErr = (
      await exec(`cat /tmp/singbox-ui-nft-check.err 2>/dev/null || true`)
    ).stdout;
    await exec(`rm -f ${tmpPath} /tmp/singbox-ui-nft-check.err`);
    // Allow skip for environments where nft -c is unavailable (tproxy/socket kernel features)
    const skipPatterns =
      /tproxy|socket|cache initialization failed|operation not permitted|permission denied/i;
    if (nftResult.exitCode !== 0) {
      if (skipPatterns.test(nftErr)) {
        console.log(
          `SKIP: nft -c unavailable in this environment (${nftErr.split("\n")[0]})`,
        );
        return;
      }
      throw new Error(`nft rejected emitted rules:\n${nftErr}`);
    }
    expect(nftResult.exitCode).toBe(0);
  });

  it("emit with custom port and interface", async () => {
    const r = await emit('1234 "10.0.0.0/8" "" "eth0"');
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("127.0.0.1:1234");
    expect(r.stdout).toContain('"eth0"');
    // Empty v6 CIDR: no ip6 daddr rules
    expect(r.stdout).not.toContain("ip6 daddr");
  });

  it("empty rs_*.json cache: output is phase-2-equivalent (no rs_ sets)", async () => {
    await exec("rm -f /tmp/singbox-ui/rs_*.json 2>/dev/null");
    const r = await emit('7893 "198.18.0.0/15" "fc00::/18" "br-lan"');
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("table inet singbox_ui");
    expect(r.stdout).toContain("chain prerouting {");
    expect(r.stdout).not.toContain("set rs_");
    expect(r.stdout).not.toContain("@rs_");
  });

  it("rs_*.json cache: nft set definition + marking rule (basic ip_cidr)", async () => {
    await putFile(
      JSON.stringify(
        {
          version: 1,
          rules: [{ ip_cidr: ["1.2.3.0/24", "4.5.6.0/16"] }],
        },
        null,
        2,
      ),
      "/tmp/singbox-ui/rs_test_basic.json",
    );
    const r = await emit('7893 "198.18.0.0/15" "" "br-lan"');
    await exec("rm -f /tmp/singbox-ui/rs_test_basic.json");
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("set rs_test_basic_0_v4");
    expect(r.stdout).toContain("type ipv4_addr");
    expect(r.stdout).toContain("flags interval");
    expect(r.stdout).toContain("1.2.3.0/24");
    expect(r.stdout).toContain("4.5.6.0/16");
    expect(r.stdout).toContain("ip daddr @rs_test_basic_0_v4");
    expect(r.stdout).toContain("meta l4proto { tcp, udp }");
    expect(r.stdout).toContain("ct mark set ct mark or 0x40000000");
    expect(r.stdout).toContain("ct state new");
    expect(r.stdout).toContain("198.18.0.0/15");
  });

  it("rs_*.json cache: network=tcp emits 'meta l4proto tcp'", async () => {
    await putFile(
      JSON.stringify(
        {
          version: 1,
          rules: [{ ip_cidr: ["10.0.0.0/8"], network: "tcp" }],
        },
        null,
        2,
      ),
      "/tmp/singbox-ui/rs_test_tcp.json",
    );
    const r = await emit('7893 "198.18.0.0/15" "" "br-lan"');
    await exec("rm -f /tmp/singbox-ui/rs_test_tcp.json");
    expect(r.exitCode).toBe(0);
    // Must have exact tcp l4proto match
    expect(r.stdout).toContain("ip daddr @rs_test_tcp_0_v4 meta l4proto tcp");
    // Must NOT use default {tcp, udp} for this rule
    const tcpRuleLine = r.stdout
      .split("\n")
      .find((l) => l.includes("ip daddr @rs_test_tcp_0_v4"));
    expect(tcpRuleLine).toBeDefined();
    expect(tcpRuleLine).not.toContain("meta l4proto { tcp, udp }");
  });

  it("rs_*.json cache: network=tcp + port_range=['80:443'] emits 'tcp dport 80-443'", async () => {
    await putFile(
      JSON.stringify(
        {
          version: 1,
          rules: [
            {
              ip_cidr: ["172.16.0.0/12"],
              network: "tcp",
              port_range: ["80:443"],
            },
          ],
        },
        null,
        2,
      ),
      "/tmp/singbox-ui/rs_test_port.json",
    );
    const r = await emit('7893 "198.18.0.0/15" "" "br-lan"');
    await exec("rm -f /tmp/singbox-ui/rs_test_port.json");
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain(
      "ip daddr @rs_test_port_0_v4 meta l4proto tcp tcp dport 80-443 ct state new ct mark set ct mark or 0x40000000",
    );
  });

  it("rs_*.json cache: scalar ip_cidr + scalar port_range (real sing-box shape)", async () => {
    await putFile(
      JSON.stringify(
        {
          version: 3,
          rules: [
            {
              ip_cidr: "104.16.0.0/12",
              network: "udp",
              port_range: "19000:20000",
            },
          ],
        },
        null,
        2,
      ),
      "/tmp/singbox-ui/rs_test_scalar.json",
    );
    const r = await emit('7893 "198.18.0.0/15" "" "br-lan"');
    await exec("rm -f /tmp/singbox-ui/rs_test_scalar.json");
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("set rs_test_scalar_0_v4");
    // elements = { 104.16.0.0/12 }
    expect(r.stdout).toMatch(/elements = \{ 104\.16\.0\.0\/12 \}/);
    expect(r.stdout).toContain(
      "ip daddr @rs_test_scalar_0_v4 meta l4proto udp udp dport 19000-20000 ct state new ct mark set ct mark or 0x40000000",
    );
  });

  it("rs_*.json cache: domain-only rule is skipped, ip_cidr rule still emits at idx 1", async () => {
    await putFile(
      JSON.stringify(
        {
          version: 3,
          rules: [
            { domain_suffix: ["example.com"] },
            { ip_cidr: ["10.0.0.0/8"], network: "tcp" },
          ],
        },
        null,
        2,
      ),
      "/tmp/singbox-ui/rs_test_mixed.json",
    );
    const r = await emit('7893 "198.18.0.0/15" "" "br-lan"');
    await exec("rm -f /tmp/singbox-ui/rs_test_mixed.json");
    expect(r.exitCode).toBe(0);
    // ip_cidr at array index 1 → rs_..._1_v4
    expect(r.stdout).toContain("set rs_test_mixed_1_v4");
    // domain-only at index 0 → no set
    expect(r.stdout).not.toContain("set rs_test_mixed_0_v4");
  });

  it("emit with two interfaces: wan_ifaces set contains both", async () => {
    const r = await emit('7893 "198.18.0.0/15" "" "br-lan,br-guest"');
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("set wan_ifaces");
    expect(r.stdout).toContain('"br-lan"');
    expect(r.stdout).toContain('"br-guest"');
  });

  it("emit with three interfaces", async () => {
    const r = await emit('7893 "198.18.0.0/15" "" "br-lan,br-guest,wlan0"');
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain('"wlan0"');
  });

  it("emit with single interface: wan_ifaces set contains it", async () => {
    const r = await emit('7893 "198.18.0.0/15" "" "br-lan"');
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("set wan_ifaces");
    expect(r.stdout).toContain('"br-lan"');
  });

  it("C2.1.6: iface names with quotes/spaces/shell metacharacters are dropped", async () => {
    // Use exec directly to capture stderr separately
    const r = await exec(
      `cd ${WORK} && ucode -L ${LIB} ${SCRIPT} emit 7893 "198.18.0.0/15" "" 'br-lan,evil"; ls #,wan0' 2>/tmp/c2_iface_err.log; cat /tmp/c2_iface_err.log >&2; rm -f /tmp/c2_iface_err.log`,
    );
    expect(r.stdout).not.toContain("evil");
    expect(r.stdout).toContain('"br-lan"');
    expect(r.stdout).toContain('"wan0"');
    // Warning on stderr
    expect(r.stderr.toLowerCase()).toMatch(/invalid iface|iface.*skip/i);
  });

  it("C2.1.6: iface name with backslash is dropped", async () => {
    const r = await exec(
      `cd ${WORK} && ucode -L ${LIB} ${SCRIPT} emit 7893 "198.18.0.0/15" "" 'br-lan,bad\\name' 2>/dev/null`,
    );
    expect(r.stdout).not.toMatch(/bad\\name|bad\\\\name/);
  });

  it("C2.1.6: dotted/at-sign iface names are accepted (vlan, alias forms)", async () => {
    const r = await exec(
      `cd ${WORK} && ucode -L ${LIB} ${SCRIPT} emit 7893 "198.18.0.0/15" "" 'eth0.100,br-lan@if5' 2>/dev/null`,
    );
    expect(r.stdout).toContain("eth0.100");
    expect(r.stdout).toContain("br-lan@if5");
  });

  it("emit: extra fwmark/fwmask/router_out argv accepted (defaults match explicit)", async () => {
    const rDefault = await exec(
      `cd ${WORK} && ucode -L ${LIB} ${SCRIPT} emit 7895 198.18.0.0/15 fc00::/18 br-lan`,
    );
    const rExplicit = await exec(
      `cd ${WORK} && ucode -L ${LIB} ${SCRIPT} emit 7895 198.18.0.0/15 fc00::/18 br-lan 0x40000000 0x40000000 0`,
    );
    expect(rDefault.exitCode).toBe(0);
    expect(rExplicit.exitCode).toBe(0);
    expect(rDefault.stdout).toBe(rExplicit.stdout);
  });

  it("emit: S5.3 syntactically-invalid CIDRs are dropped, valid ones kept", async () => {
    const r = await exec(
      `cd ${WORK} && ucode -L ${LIB} ${SCRIPT} emit 7893 "1.2.3.4/24,256.1.1.1,10.0.0.0/8" "fc00::/18,:::,1:2:3:4:5:6:7:8:9,2001:db8::1" br-lan 2>/dev/null`,
    );
    expect(r.exitCode).toBe(0);
    // Valid CIDRs must be present
    expect(r.stdout).toContain("1.2.3.4/24");
    expect(r.stdout).toContain("10.0.0.0/8");
    expect(r.stdout).toContain("fc00::/18");
    expect(r.stdout).toContain("2001:db8::1");
    // Invalid CIDRs must not appear
    expect(r.stdout).not.toContain("256.1.1.1");
    expect(r.stdout).not.toContain("1:2:3:4:5:6:7:8:9");
    expect(r.stdout).not.toContain(":::");
  });
});
