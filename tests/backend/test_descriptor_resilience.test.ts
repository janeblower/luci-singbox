import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

// Port of tests/backend/test_descriptor_resilience.sh
// S2.1: a broken built-in descriptor must log+skip, not abort ALL config generation.
// outbound.uc / inbound.uc wrap their eager require() so one malformed descriptor
// file degrades gracefully instead of throwing and killing generation for every
// protocol.
//
// Strategy: place a broken "trojan" overlay in a higher-priority -L path so it
// shadows the real trojan descriptor. Then verify vless still generates (outbound)
// and tproxy/vless still generate (inbound).

const LIB =
  process.env.SB_VM_LIB ?? "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";
const WORK = process.env.SB_VM_WORK ?? "/tmp/work";

// Broken trojan descriptor: register() asserts emit is a function; providing
// none causes the require() to throw at load, just like a real broken file.
const BROKEN_TROJAN_UC = `
// Broken trojan descriptor — no emit() and no fields[] → register() throws.
let reg = require("builder.protocols.registry");
reg.register({ kind: "outbound", type: "trojan", sing_box_type: "trojan" });
`;

const BROKEN_TROJAN_INBOUND_UC = `
// Broken trojan inbound descriptor — no emit() and no fields[] → throws.
let reg = require("builder.protocols.registry");
reg.register({ kind: "inbound", type: "trojan", sing_box_type: "trojan" });
`;

describe("descriptor resilience (S2.1)", () => {
  useGuest();

  it("outbound: broken trojan descriptor does not stop vless from generating", async () => {
    // Stage a broken trojan descriptor in a temp overlay dir
    const overlayDir = `/tmp/sb-resilience-${process.pid}/builder/protocols`;
    await exec(`mkdir -p ${overlayDir}`);
    const put = await putFile(BROKEN_TROJAN_UC, `${overlayDir}/trojan.uc`);
    expect(put.exitCode).toBe(0);

    // Run outbound builder with overlay dir FIRST on -L path (shadows real trojan).
    // Use putFile() to write the ucode script to avoid shell quoting issues.
    const src = [
      "let ob = require('outbound');",
      "let s = {",
      "  '.name': 'vless_test', type: 'vless',",
      "  server: '1.2.3.4', server_port: '443',",
      "  server_uuid: '11111111-2222-3333-4444-555555555555',",
      "};",
      "let got = ob.build_constructor_for(s, 'vless');",
      "print(got != null && got.type === 'vless' ? 'PASS' : sprintf('FAIL:%J', got));",
    ].join("\n");

    const overlayBase = `/tmp/sb-resilience-${process.pid}`;
    const scriptPath = `${overlayBase}/test_script.uc`;
    await putFile(src, scriptPath);
    const r = await exec(
      `cd ${WORK} && ucode -L ${overlayBase} -L ${LIB} ${scriptPath} 2>/dev/null`,
    );
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("PASS");

    await exec(`rm -rf ${overlayBase}`);
  });

  it("inbound: broken trojan descriptor does not stop vless inbound from generating", async () => {
    const overlayDir = `/tmp/sb-resilience-in-${process.pid}/builder/protocols`;
    await exec(`mkdir -p ${overlayDir}`);
    const put = await putFile(
      BROKEN_TROJAN_INBOUND_UC,
      `${overlayDir}/trojan.uc`,
    );
    expect(put.exitCode).toBe(0);

    const src = [
      "let inb = require('inbound');",
      "let s = {",
      "  '.name': 'vless_in', '.type': 'inbound',",
      "  enabled: '1', protocol: 'vless',",
      "  listen: '::', listen_port: '443',",
      "  server_uuid: '99999999-aaaa-bbbb-cccc-dddddddddddd',",
      "};",
      "let got = inb.build_one(s);",
      "print(got != null && got.type === 'vless' ? 'PASS' : sprintf('FAIL:%J', got));",
    ].join("\n");

    const overlayBase = `/tmp/sb-resilience-in-${process.pid}`;
    const scriptPath = `${overlayBase}/test_script.uc`;
    await putFile(src, scriptPath);
    const r = await exec(
      `cd ${WORK} && ucode -L ${overlayBase} -L ${LIB} ${scriptPath} 2>/dev/null`,
    );
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("PASS");

    await exec(`rm -rf ${overlayBase}`);
  });

  it("outbound: trojan itself returns null when its descriptor is broken", async () => {
    const overlayDir = `/tmp/sb-resilience-trojan-${process.pid}/builder/protocols`;
    await exec(`mkdir -p ${overlayDir}`);
    const put = await putFile(BROKEN_TROJAN_UC, `${overlayDir}/trojan.uc`);
    expect(put.exitCode).toBe(0);

    const src = [
      "let ob = require('outbound');",
      "let s = {",
      "  '.name': 'tj', type: 'trojan',",
      "  server: '1.2.3.4', server_port: '443',",
      "  server_password: 'pw',",
      "};",
      "let got = ob.build_constructor_for(s, 'trojan');",
      "// broken descriptor → no descriptor registered → build_constructor_for returns null",
      "print(got == null ? 'PASS_NULL' : sprintf('GOT:%J', got));",
    ].join("\n");

    const overlayBase = `/tmp/sb-resilience-trojan-${process.pid}`;
    const scriptPath = `${overlayBase}/test_script.uc`;
    await putFile(src, scriptPath);
    const r = await exec(
      `cd ${WORK} && ucode -L ${overlayBase} -L ${LIB} ${scriptPath} 2>/dev/null`,
    );
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("PASS_NULL");

    await exec(`rm -rf ${overlayBase}`);
  });
});
