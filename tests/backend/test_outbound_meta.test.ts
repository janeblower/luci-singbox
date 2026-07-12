import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

// Phase 0 regressions: tag != display name.
//   - subscription tags were POSITIONAL (sub__0, sub__1): a provider reordering
//     its node list silently moved the selector's pick onto another server;
//   - the node name went through safe_tag(), so "🇳🇱 Умная локация" became
//     imported-<hash> and the dashboard showed junk.
// Tags are now derived from node CONTENT (fnv1a of type|server|port|uuid|
// password|method) and the raw UTF-8 name lives in the outbound-meta side-car.

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB = `${WORK}/singbox-ui/root/usr/share/singbox-ui/lib`;
const GENERATE_UC = `${WORK}/singbox-ui/root/usr/share/singbox-ui/generate.uc`;

const NODE_A =
  "vless://11111111-1111-1111-1111-111111111111@a.example:443?security=tls#%F0%9F%87%B3%F0%9F%87%B1%20%D0%A3%D0%BC%D0%BD%D0%B0%D1%8F%20%D0%BB%D0%BE%D0%BA%D0%B0%D1%86%D0%B8%D1%8F";
const NODE_B = "trojan://pw@b.example:8443#Node%20B";
const NODE_C = "hy2://pw2@c.example:443#Node%20C";

describe("outbound meta / content-derived tags", () => {
  useGuest();

  const base = `/tmp/obmeta_${process.pid}`;
  const sandbox = `${base}/sandbox`;
  const subs = `${sandbox}/subs`;
  const cfgJson = `${sandbox}/singbox-ui.json`;
  const metaJson = `${subs}/outbound-meta.json`;

  // Runs generate.uc (production entrypoint) with the given subscription body,
  // returns { tags, meta } read back from the generated config + side-car.
  async function gen(links: string[]): Promise<{
    tags: string[];
    meta: Record<string, { name: string; type: string; link: string }>;
    members: string[];
  }> {
    await exec(`rm -rf ${base}; mkdir -p ${subs}`);
    await putFile(
      `
config outbound 'mysub'
\toption type 'subscription'
\toption sub_url 'http://example.test/x'
\toption sub_multi '1'
`,
      `${base}/singbox-ui`,
    );
    await putFile(`${links.join("\n")}\n`, `${subs}/sub_mysub.txt`);

    const r = await exec(
      `cd ${WORK} && UCI_CONFIG_DIR=${base} SINGBOX_TMPDIR=${subs} SINGBOX_CONFIG=${cfgJson} ucode -L ${LIB} ${GENERATE_UC} >/dev/null 2>&1; echo rc=$?`,
    );
    expect(r.stdout).toContain("rc=0");

    const cfg = JSON.parse((await exec(`cat ${cfgJson}`)).stdout);
    const meta = JSON.parse((await exec(`cat ${metaJson}`)).stdout);
    const group = cfg.outbounds.find(
      (o: { tag: string }) => o.tag === "mysub",
    ) as { outbounds: string[] };
    return {
      tags: cfg.outbounds
        .map((o: { tag: string }) => o.tag)
        .filter((t: string) => t.startsWith("mysub__")),
      meta,
      members: group.outbounds,
    };
  }

  it("tag is stable when the provider reorders the subscription", async () => {
    const first = await gen([NODE_A, NODE_B, NODE_C]);
    const second = await gen([NODE_C, NODE_A, NODE_B]);

    expect(first.tags.length).toBe(3);
    // Same nodes, different order -> same tag set (positional tags would give
    // mysub__0 to a different node and move the selector's pick).
    expect([...second.tags].sort()).toEqual([...first.tags].sort());
    // ...and each tag still points at the same server.
    for (const t of first.tags)
      expect(second.meta[t].link).toBe(first.meta[t].link);
  });

  it("display_name carries emoji + Cyrillic verbatim; tag stays ASCII-safe", async () => {
    const { tags, meta } = await gen([NODE_A, NODE_B]);
    const names = Object.values(meta).map((m) => m.name);
    expect(names).toContain("🇳🇱 Умная локация");
    expect(names).toContain("Node B");
    for (const t of tags) {
      expect(t).toMatch(/^[A-Za-z0-9_.-]+$/); // valid sing-box tag
      expect(meta[t].type).toBeTruthy();
      expect(meta[t].link).toMatch(/^[a-z2]+:\/\//);
    }
  });

  it("identical nodes collide on the same hash but do not break the config", async () => {
    const { tags, members } = await gen([NODE_B, NODE_B]);
    expect(tags.length).toBe(2); // both survive, one gets a _2 suffix
    expect(new Set(tags).size).toBe(2);
    expect([...members].sort()).toEqual([...tags].sort());
    expect(tags.some((t) => t.endsWith("_2"))).toBe(true);
  });

  it("side-car is 0600 (it embeds share-links with passwords/uuids)", async () => {
    await gen([NODE_A]);
    // OpenWrt BusyBox has no stat(1) — read the mode bits off ls -l.
    const r = await exec(`ls -l ${metaJson} | cut -c1-10`);
    expect(r.stdout.trim()).toBe("-rw-------");
  });
});
