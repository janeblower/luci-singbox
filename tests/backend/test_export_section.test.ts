import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

// Regression for F-16/U-08. export_section used to gate on
// helpers.is_outbound_proxy_kind(), a hand-kept list that covered only the proxy
// protocols — so the UI's "view JSON" button failed with `unknown outbound type:
// direct` on every direct / selector / urltest / json / sharelink section, all of
// which build_outbounds() builds without complaint. The gate now asks the
// registry, which is the single source of truth for what a descriptor exists for.
//
// Driven through the PRODUCTION path (the rpcd handler), not `ucode -L lib`:
// export_section runs IN-PROCESS in the handler now — the ~40-line forked
// wrapper script it used to shell out to is gone — so the handler IS the unit.

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const SB = `${WORK}/singbox-ui/root/usr/share/singbox-ui`;
const RPCD = `${WORK}/singbox-ui/root/usr/libexec/rpcd/singbox-ui`;

async function exportOutbound(
  name: string,
  uci: string[],
): Promise<{ status: string; message?: string; section?: any }> {
  const cfg = `/tmp/es_uci_${name}`;
  await exec(`rm -rf ${cfg} && mkdir -p ${cfg}`);
  await putFile(`${uci.join("\n")}\n`, `${cfg}/singbox-ui`);
  const body = JSON.stringify({ kind: "outbound", name }).replace(
    /'/g,
    `'\\''`,
  );
  const r = await exec(
    `cd ${WORK} && printf '%s' '${body}' | UCI_CONFIG_DIR=${cfg} UCODE_LIB=${SB}/lib ucode -L ${SB}/lib ${RPCD} call export_section; rm -rf ${cfg}`,
  );
  expect(r.exitCode).toBe(0);
  return JSON.parse(r.stdout);
}

describe("export_section", () => {
  useGuest();

  it("exports a direct outbound (was: unknown outbound type: direct)", async () => {
    const r = await exportOutbound("es_direct", [
      "config outbound 'es_direct'",
      "\toption type 'direct'",
      "\toption enabled '1'",
    ]);
    expect(r.status).toBe("ok");
    expect(r.section.type).toBe("direct");
  });

  it("exports a selector group", async () => {
    const r = await exportOutbound("es_sel", [
      "config outbound 'es_sel'",
      "\toption type 'selector'",
      "\toption enabled '1'",
      "\tlist group_outbounds 'a'",
      "\tlist group_outbounds 'b'",
    ]);
    expect(r.status).toBe("ok");
    expect(r.section.type).toBe("selector");
  });

  it("still refuses a genuinely unknown type", async () => {
    const r = await exportOutbound("es_bogus", [
      "config outbound 'es_bogus'",
      "\toption type 'not_a_protocol'",
      "\toption enabled '1'",
    ]);
    expect(r.status).toBe("error");
    expect(r.message).toContain("unknown outbound type");
  });

  it("still refuses the UI-only shapes (subscription)", async () => {
    const r = await exportOutbound("es_sub", [
      "config outbound 'es_sub'",
      "\toption type 'subscription'",
      "\toption enabled '1'",
    ]);
    expect(r.status).toBe("error");
    expect(r.message).toContain("does not support type=subscription");
  });

  it("a builder failure comes back as an error, not a dead handler", async () => {
    // The fork used to buy isolation from a die() inside the lib. In-process,
    // try/catch -> emit_err is what buys it — assert the handler still answers.
    const r = await exportOutbound("es_missing", [
      "config outbound 'somebody_else'",
      "\toption type 'direct'",
    ]);
    expect(r.status).toBe("error");
  });
});
