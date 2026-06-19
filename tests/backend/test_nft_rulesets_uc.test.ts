import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

const LIB =
  process.env.SB_VM_LIB ?? "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";
const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const SUB_UC = `${WORK}/singbox-ui/root/usr/share/singbox-ui/nft-rulesets.uc`;
const TMP = `/tmp/sb-rulesets-${process.pid}`;
const RUNTIME = `${TMP}/runtime`;

async function runUc(
  ...args: string[]
): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  const argStr = args.map((a) => `'${a.replace(/'/g, "'\\''")}'`).join(" ");
  return exec(
    `cd ${WORK} && UCI_CONFIG_DIR=${TMP} SINGBOX_TMPDIR=${RUNTIME} ucode -L ${LIB} ${SUB_UC} ${argStr} 2>&1 || true`,
  );
}

async function writeUci(content: string): Promise<void> {
  await putFile(content, `${TMP}/singbox-ui`);
}

describe("nft_rulesets_uc", () => {
  useGuest();

  beforeAll(async () => {
    await exec(`mkdir -p ${TMP}/src ${RUNTIME}`);
  });

  afterAll(async () => {
    await exec(`rm -rf ${TMP}`);
  });

  it("fetch copies local .json source to rs_<name>.json", async () => {
    await exec(`mkdir -p ${TMP}/src`);
    await putFile('{"version":1,"rules":[]}\n', `${TMP}/src/r.json`);
    await writeUci(
      `config ruleset 'rA'\n\toption type 'local'\n\toption path '${TMP}/src/r.json'\n\toption nft_rules '1'\n`,
    );
    await runUc("fetch");
    const check = await exec(
      `test -s ${RUNTIME}/rs_rA.json && grep -q '"rules"' ${RUNTIME}/rs_rA.json`,
    );
    expect(check.exitCode, "rs_rA.json must exist and contain rules").toBe(0);
  });

  it("C2.1.8: local ruleset path outside whitelist is rejected", async () => {
    await writeUci(
      `config ruleset 'rs1'\n\toption type 'local'\n\toption path '/root/secret.json'\n\toption nft_rules '1'\n`,
    );
    await exec(`rm -f ${RUNTIME}/rs_rs1.json ${RUNTIME}/rs_rs1.raw`);
    const r = await runUc("fetch");
    expect(r.stdout).toMatch(/outside whitelist|invalid path|reject/i);
    const notCreated = await exec(
      `test -f ${RUNTIME}/rs_rs1.json || test -f ${RUNTIME}/rs_rs1.raw`,
    );
    expect(notCreated.exitCode, "rs_rs1 file must NOT be created").not.toBe(0);
  });

  it("C2.1.8: local ruleset under /tmp is accepted", async () => {
    await exec(`mkdir -p ${TMP}/safe`);
    await putFile('{"version":1,"rules":[]}\n', `${TMP}/safe/s.json`);
    await writeUci(
      `config ruleset 'rS'\n\toption type 'local'\n\toption path '${TMP}/safe/s.json'\n\toption nft_rules '1'\n`,
    );
    await runUc("fetch");
    const check = await exec(`test -s ${RUNTIME}/rs_rS.json`);
    expect(check.exitCode, "rs_rS.json must exist").toBe(0);
  });

  it("C2.1.16: nft-rulesets.uc has raw_path cleanup in local cp-failure branch", async () => {
    const r = await exec(
      `grep -qE '(fs\\.unlink|unlink_quiet)\\(raw_path\\)' ${SUB_UC}`,
    );
    expect(r.exitCode, "raw_path cleanup must be present").toBe(0);
  });

  it("SEC-9: unlink_quiet helper exists; no bare fs.unlink(m.raw_path) in decompile loop", async () => {
    const r1 = await exec(`grep -qE 'function unlink_quiet' ${SUB_UC}`);
    expect(r1.exitCode, "unlink_quiet helper must exist").toBe(0);
    const r2 = await exec(`grep -qE 'fs\\.unlink\\(m\\.raw_path\\)' ${SUB_UC}`);
    expect(
      r2.exitCode,
      "bare fs.unlink(m.raw_path) must not exist in loop",
    ).not.toBe(0);
  });

  it("S3-3: symlink to /proc/version (outside whitelist) is rejected", async () => {
    await exec(`ln -sf /proc/version ${TMP}/src/evil.json`);
    await writeUci(
      `config ruleset 'rsEvil'\n\toption type 'local'\n\toption path '${TMP}/src/evil.json'\n\toption nft_rules '1'\n`,
    );
    await exec(`rm -f ${RUNTIME}/rs_rsEvil.json ${RUNTIME}/rs_rsEvil.raw`);
    const r = await runUc("fetch");
    expect(r.stdout).toMatch(
      /outside the whitelist|not a regular file|escaping|reject/i,
    );
    const notCreated = await exec(`test -f ${RUNTIME}/rs_rsEvil.json`);
    expect(notCreated.exitCode).not.toBe(0);
    await exec(`rm -f ${TMP}/src/evil.json`);
  });

  it("S3-3 allow: symlink pointing to in-whitelist file is allowed", async () => {
    await putFile('{"version":1,"rules":[]}\n', `${TMP}/src/target.json`);
    await exec(`ln -sf ${TMP}/src/target.json ${TMP}/src/link.json`);
    await writeUci(
      `config ruleset 'rsOk'\n\toption type 'local'\n\toption path '${TMP}/src/link.json'\n\toption nft_rules '1'\n`,
    );
    await exec(`rm -f ${RUNTIME}/rs_rsOk.json`);
    const r = await runUc("fetch");
    expect(r.stdout).not.toMatch(
      /outside the whitelist|not a regular file|escaping/i,
    );
    const check = await exec(`test -s ${RUNTIME}/rs_rsOk.json`);
    expect(check.exitCode, "in-whitelist symlink must produce rs file").toBe(0);
    await exec(`rm -f ${TMP}/src/link.json ${TMP}/src/target.json`);
  });

  it("SEC-8: multi-hop symlink chain escaping whitelist is rejected", async () => {
    await exec(`ln -sf /proc/version ${TMP}/src/hop2.json`);
    await exec(`ln -sf ${TMP}/src/hop2.json ${TMP}/src/chain1.json`);
    await writeUci(
      `config ruleset 'rsChain'\n\toption type 'local'\n\toption path '${TMP}/src/chain1.json'\n\toption nft_rules '1'\n`,
    );
    await exec(`rm -f ${RUNTIME}/rs_rsChain.json ${RUNTIME}/rs_rsChain.raw`);
    const r = await runUc("fetch");
    expect(r.stdout).toMatch(
      /outside the whitelist|not a regular file|escaping|reject/i,
    );
    const notCreated = await exec(`test -f ${RUNTIME}/rs_rsChain.json`);
    expect(notCreated.exitCode).not.toBe(0);
    await exec(`rm -f ${TMP}/src/chain1.json ${TMP}/src/hop2.json`);
  });

  it("SEC-8: symlinked parent directory escaping whitelist is rejected", async () => {
    await exec(`ln -sf /proc ${TMP}/src/pdir`);
    await writeUci(
      `config ruleset 'rsParent'\n\toption type 'local'\n\toption path '${TMP}/src/pdir/version'\n\toption nft_rules '1'\n`,
    );
    await exec(`rm -f ${RUNTIME}/rs_rsParent.json ${RUNTIME}/rs_rsParent.raw`);
    const r = await runUc("fetch");
    expect(r.stdout).toMatch(
      /outside the whitelist|not a regular file|escaping/i,
    );
    const notCreated = await exec(`test -f ${RUNTIME}/rs_rsParent.json`);
    expect(notCreated.exitCode).not.toBe(0);
    await exec(`rm -rf ${TMP}/src/pdir`);
  });

  it("regression: tproxy inbound with nft_rules=1 is NOT treated as a ruleset", async () => {
    await writeUci(
      `config inbound 'tproxy_in'\n\toption enabled '1'\n\toption protocol 'tproxy'\n\toption listen_port '7895'\n\toption nft_rules '1'\n`,
    );
    const r = await runUc("fetch");
    expect(r.stdout).not.toMatch(/unknown type.*tproxy/i);
    expect(r.stdout).toMatch(/no rule-sets configured/i);
  });
});
