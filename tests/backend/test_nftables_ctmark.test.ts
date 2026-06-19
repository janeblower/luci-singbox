import { afterAll, describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

const LIB =
  process.env.SB_VM_LIB ?? "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";
const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const SCRIPT = `${WORK}/singbox-ui/root/usr/share/singbox-ui/nftables.uc`;

async function emit(...args: string[]): Promise<string> {
  const argStr = args.map((a) => `'${a.replace(/'/g, "'\\''")}'`).join(" ");
  const r = await exec(
    `cd ${WORK} && ucode -L ${LIB} ${SCRIPT} emit ${argStr}`,
  );
  if (r.exitCode !== 0)
    throw new Error(`emit failed (exit ${r.exitCode}): ${r.stderr}`);
  return r.stdout;
}

/** Return count of non-overlapping matches of literal string in haystack. */
function countMatches(haystack: string, needle: string): number {
  let count = 0;
  let pos = haystack.indexOf(needle, 0);
  while (pos !== -1) {
    count++;
    pos = haystack.indexOf(needle, pos + needle.length);
  }
  return count;
}

/** First non-type, non-empty rule line inside 'chain prerouting {' block. */
function firstPreroutingRule(out: string): string {
  const lines = out.split("\n");
  let inChain = false;
  for (const line of lines) {
    if (/chain prerouting \{/.test(line)) {
      inChain = true;
      continue;
    }
    if (!inChain) continue;
    if (/^\t\ttype/.test(line)) continue;
    if (/^[^\t]/.test(line)) break; // exited chain
    if (/^\t\t[^\s]/.test(line)) return line;
  }
  return "";
}

describe("nftables_ctmark", () => {
  useGuest();

  afterAll(async () => {
    await exec("rm -f /tmp/singbox-ui/rs_ctmarktest.json");
  });

  it("t_fakeip_named_set: fakeip4 and fakeip6 are named sets, not literal in daddr", async () => {
    const out = await emit("7895", "198.18.0.0/15", "fc00::/18", "br-lan");
    expect(out).toContain("set fakeip4 {");
    expect(out).toContain("set fakeip6 {");
    expect(out).not.toContain("daddr { 198.18");
  });

  it("t_wan_ifaces_named_set: wan_ifaces is a named set with type ifname", async () => {
    const out = await emit("7895", "198.18.0.0/15", "fc00::/18", "br-lan");
    expect(out).toContain("set wan_ifaces {");
    // line after 'set wan_ifaces {' should have 'type ifname'
    const lines = out.split("\n");
    const idx = lines.findIndex((l) => l.includes("set wan_ifaces"));
    const typeLines = lines.slice(idx + 1).find((l) => l.includes("type"));
    expect(typeLines).toContain("type ifname");
    // no literal iifname { "x", "y" } in chain body
    const ifaceLines = lines.filter((l) => l.includes("iifname"));
    for (const l of ifaceLines) expect(l).not.toMatch(/\{ "/);
  });

  it("t_socket_transparent_fast_path_first", async () => {
    const out = await emit("7895", "198.18.0.0/15", "fc00::/18", "br-lan");
    const firstRule = firstPreroutingRule(out);
    expect(firstRule).toContain("socket transparent 1");
  });

  it("t_ct_mark_or_assignment: >= 2 ct mark decisions, none use meta mark set", async () => {
    const out = await emit("7895", "198.18.0.0/15", "fc00::/18", "br-lan");
    const n = countMatches(out, "ct mark set ct mark or 0x40000000");
    expect(n).toBeGreaterThanOrEqual(2);
    const decisionLines = out
      .split("\n")
      .filter((l) => l.includes("ct state new"));
    for (const l of decisionLines) expect(l).not.toContain("meta mark set");
  });

  it("t_mark_restore_twice: exactly 2 mark-restore lines", async () => {
    const out = await emit("7895", "198.18.0.0/15", "fc00::/18", "br-lan");
    const n = out
      .split("\n")
      .filter((l) => /^\s*meta mark set ct mark$/.test(l)).length;
    expect(n).toBe(2);
  });

  it("t_tproxy_uses_and_mask: AND-mask not exact equality", async () => {
    const out = await emit("7895", "198.18.0.0/15", "fc00::/18", "br-lan");
    expect(out).toContain("meta mark and 0x40000000 == 0x40000000");
    expect(out).not.toContain("meta mark 0x40000000 meta l4proto");
  });

  it("t_custom_fwmark_propagates: custom mark and mask propagate correctly", async () => {
    const out2 = await emit(
      "7895",
      "198.18.0.0/15",
      "fc00::/18",
      "br-lan",
      "0x100",
      "0xff00",
      "0",
    );
    expect(out2).toContain("ct mark set ct mark or 0x100");
    expect(out2).toContain("meta mark and 0xff00 == 0x100");
    expect(out2).toContain("socket transparent 1 meta mark set 0x100");
  });

  it("t_router_output_chain: router_out=1 produces output chain", async () => {
    const out3 = await emit(
      "7895",
      "198.18.0.0/15",
      "fc00::/18",
      "br-lan",
      "0x1",
      "0x1",
      "1",
    );
    expect(out3).toContain("chain output {");
    expect(out3).toContain("type route hook output priority mangle");
  });

  it("t_rs_decision_uses_ct_mark: rs_* decisions use ct mark, not meta mark", async () => {
    await exec("mkdir -p /tmp/singbox-ui");
    await putFile(
      '{"rules":[{"ip_cidr":["9.9.9.0/24"]}]}\n',
      "/tmp/singbox-ui/rs_ctmarktest.json",
    );
    const out6 = await emit("7895", "198.18.0.0/15", "fc00::/18", "br-lan");
    const rsLines = out6
      .split("\n")
      .filter((l) => l.includes("@rs_ctmarktest_0_v4"));
    expect(rsLines.some((l) => l.includes("ct mark set ct mark or"))).toBe(
      true,
    );
    expect(rsLines.some((l) => l.includes("meta mark set"))).toBe(false);
  });
});
