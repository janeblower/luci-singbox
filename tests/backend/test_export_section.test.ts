import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec } from "../helpers/ssh.ts";

// Regression for F-16/U-08. export_section used to gate on
// helpers.is_outbound_proxy_kind(), a hand-kept list that covered only the proxy
// protocols — so the UI's "view JSON" button failed with `unknown outbound type:
// direct` on every direct / selector / urltest / json / sharelink section, all of
// which build_outbounds() builds without complaint. The gate now asks the
// registry, which is the single source of truth for what a descriptor exists for.
const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB =
  process.env.SB_VM_LIB ?? `${WORK}/singbox-ui/root/usr/share/singbox-ui/lib`;
const SCRIPT = `${WORK}/singbox-ui/root/usr/share/singbox-ui/export_section.uc`;

async function exportOutbound(
  name: string,
  uci: string[],
): Promise<{ exitCode: number; stdout: string }> {
  const cfg = `/tmp/es_uci_${name}`;
  const body = uci.map((l) => `        "${l}" \\`).join("\n");
  return exec(`
    rm -rf ${cfg}; mkdir -p ${cfg}
    printf '%s\\n' \\
${body}
        > ${cfg}/singbox-ui
    UCI_CONFIG_DIR=${cfg} ucode -L ${LIB} ${SCRIPT} outbound ${name} 2>&1
    rm -rf ${cfg}
  `);
}

describe("export_section", () => {
  useGuest();

  it("exports a direct outbound (was: unknown outbound type: direct)", async () => {
    const r = await exportOutbound("es_direct", [
      "config outbound 'es_direct'",
      "\toption type 'direct'",
      "\toption enabled '1'",
    ]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toMatch(/"status":\s*"ok"/);
    expect(r.stdout).toMatch(/"type":\s*"direct"/);
  });

  it("exports a selector group", async () => {
    const r = await exportOutbound("es_sel", [
      "config outbound 'es_sel'",
      "\toption type 'selector'",
      "\toption enabled '1'",
      "\tlist outbounds 'a'",
      "\tlist outbounds 'b'",
    ]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toMatch(/"status":\s*"ok"/);
    expect(r.stdout).toMatch(/"type":\s*"selector"/);
  });

  it("still refuses a genuinely unknown type", async () => {
    const r = await exportOutbound("es_bogus", [
      "config outbound 'es_bogus'",
      "\toption type 'not_a_protocol'",
      "\toption enabled '1'",
    ]);
    expect(r.stdout).toContain("unknown outbound type");
  });

  it("still refuses the UI-only shapes (subscription)", async () => {
    const r = await exportOutbound("es_sub", [
      "config outbound 'es_sub'",
      "\toption type 'subscription'",
      "\toption enabled '1'",
    ]);
    expect(r.stdout).toContain("does not support type=subscription");
  });
});
