import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

const LIB =
  process.env.SB_VM_LIB ?? "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";
const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const SCRIPT = `${WORK}/singbox-ui/root/usr/share/singbox-ui/nftables.uc`;
const TMP = `/tmp/sb-appsec-${process.pid}`;
const RS_DIR = "/tmp/singbox-ui";
const UCI = `${TMP}/uci`;

const GOOD_UCI = `config dns_server fakeip\n\toption type 'fakeip'\n\toption enabled '1'\n\toption inet4_range '198.18.0.0/15'\nconfig inbound tp\n\toption protocol 'tproxy'\n\toption enabled '1'\n\toption nft_rules '1'\n\toption listen_port '7895'\n\tlist interface 'br-lan'\n`;

// The rule-set sections these rs_*.json caches belong to. load_rs_rules() now
// takes an allow-set from UCI, because nothing ever DELETES an rs_*.json: an
// orphaned file used to keep marking its CIDRs into TPROXY for a rule-set the
// UI showed as off.
const RS_SECTIONS = ["aps_inj", "aps_oor", "aps_perf"]
  .map(
    (n) =>
      `config ruleset ${n}\n\toption enabled '1'\n\toption type 'remote'\n\toption nft_rules '1'\n`,
  )
  .join("");

// apply runs nftables.uc apply with stub nft, captures stderr, returns result
async function apply(): Promise<{
  stdout: string;
  stderr: string;
  exitCode: number;
}> {
  return exec(
    `cd ${WORK} && PATH=${TMP}/bin:$PATH UCI_CONFIG_DIR=${UCI} ucode -L ${LIB} ${SCRIPT} apply`,
  );
}

async function readApplied(): Promise<string> {
  const r = await exec(`cat ${TMP}/applied.nft 2>/dev/null || echo ''`);
  return r.stdout;
}

describe("nftables_apply_security", () => {
  useGuest();

  beforeAll(async () => {
    await exec(`mkdir -p ${TMP}/bin ${UCI} ${RS_DIR}`);
    // stub nft: capture -f <file> to applied.nft; exit 0 for all other calls
    // TMP is interpolated here in JS so the shell script contains the literal path
    const nftStub = `#!/bin/sh\nif [ "$1" = "-f" ]; then cat "$2" > ${TMP}/applied.nft; exit 0; fi\nexit 0\n`;
    await putFile(nftStub, `${TMP}/bin/nft`);
    await exec(`chmod +x ${TMP}/bin/nft`);
    // set up good UCI
    await putFile(GOOD_UCI + RS_SECTIONS, `${UCI}/singbox-ui`);
    // clean rs_aps_* files
    await exec(`rm -f ${RS_DIR}/rs_aps_*.json`);
  });

  afterAll(async () => {
    await exec(`rm -rf ${TMP}; rm -f ${RS_DIR}/rs_aps_*.json`);
  });

  it("S1-1: poisoned port_range in rs_*.json is not injected into applied ruleset", async () => {
    await putFile(
      '{ "rules": [ { "ip_cidr": "10.0.0.0/8", "network": "tcp", "port_range": "80 }; insert rule inet filter forward drop; #" } ] }\n',
      `${RS_DIR}/rs_aps_inj.json`,
    );
    // restore good UCI for this test
    await putFile(GOOD_UCI + RS_SECTIONS, `${UCI}/singbox-ui`);
    const r = await apply();
    expect(r.exitCode, "apply must succeed despite droppable port_range").toBe(
      0,
    );
    const applied = await readApplied();
    expect(applied).not.toContain("insert rule");
    expect(r.stderr).toContain("dropping invalid port_range");
    await exec(`rm -f ${RS_DIR}/rs_aps_inj.json`);
  });

  it("S1-1: out-of-range port_range '99999' is dropped, not applied", async () => {
    await putFile(
      '{ "rules": [ { "ip_cidr": "10.0.0.0/8", "network": "tcp", "port_range": "99999" } ] }\n',
      `${RS_DIR}/rs_aps_oor.json`,
    );
    await putFile(GOOD_UCI + RS_SECTIONS, `${UCI}/singbox-ui`);
    const r = await apply();
    expect(r.exitCode, "apply must succeed despite out-of-range port").toBe(0);
    const applied = await readApplied();
    expect(applied).not.toContain("dport 99999");
    expect(r.stderr).toContain("dropping invalid port_range");
    await exec(`rm -f ${RS_DIR}/rs_aps_oor.json`);
  });

  it("S1-PERF: apply (preloaded rs list) ≡ emit (internal load), byte-identical", async () => {
    await putFile(
      '{ "rules": [ { "ip_cidr": ["1.2.3.0/24"] } ] }\n',
      `${RS_DIR}/rs_aps_perf.json`,
    );
    await putFile(GOOD_UCI + RS_SECTIONS, `${UCI}/singbox-ui`);
    // apply path
    const applyResult = await apply();
    expect(applyResult.exitCode, "apply must succeed for S1-PERF").toBe(0);
    const applyNft = await readApplied();
    // emit path (same inputs: port=7895, v4=198.18.0.0/15, v6="", iface=br-lan)
    const emitResult = await exec(
      `cd ${WORK} && ucode -L ${LIB} ${SCRIPT} emit 7895 '198.18.0.0/15' '' 'br-lan'`,
    );
    expect(emitResult.exitCode, "emit must succeed for S1-PERF").toBe(0);
    // byte-identical
    expect(applyNft, "apply and emit must produce byte-identical output").toBe(
      emitResult.stdout,
    );
    // sanity: rs_* set made it in
    expect(applyNft).toContain("set rs_aps_perf_0_v4");
    await exec(`rm -f ${RS_DIR}/rs_aps_perf.json`);
  });

  // Nothing in the tree ever deletes an rs_*.json (nft-rulesets.uc is the only
  // writer), so unticking "Create nftables rules" — or disabling the rule-set,
  // or deleting the section — left the cache behind and the next apply rebuilt
  // its set and its `ct mark set` rule from it. Those CIDRs kept being marked
  // into TPROXY for a rule-set the UI showed as OFF, with nothing in the log,
  // surviving Apply and restart, cleared only by a reboot (tmpfs).
  it("an rs_*.json whose section no longer wants nft rules is ignored", async () => {
    await putFile(
      '{ "rules": [ { "ip_cidr": ["9.9.9.0/24"] } ] }\n',
      `${RS_DIR}/rs_aps_orphan.json`,
    );

    // 1) section present and asking for nft rules -> captured
    const withSection = `${GOOD_UCI + RS_SECTIONS}config ruleset aps_orphan\n\toption enabled '1'\n\toption type 'remote'\n\toption nft_rules '1'\n`;
    await putFile(withSection, `${UCI}/singbox-ui`);
    expect((await apply()).exitCode).toBe(0);
    expect(await readApplied()).toContain("9.9.9.0/24");

    // 2) same file, nft_rules unticked -> gone
    await putFile(
      `${GOOD_UCI + RS_SECTIONS}config ruleset aps_orphan\n\toption enabled '1'\n\toption type 'remote'\n\toption nft_rules '0'\n`,
      `${UCI}/singbox-ui`,
    );
    expect((await apply()).exitCode).toBe(0);
    expect(await readApplied()).not.toContain("9.9.9.0/24");

    // 3) section disabled -> gone
    await putFile(
      `${GOOD_UCI + RS_SECTIONS}config ruleset aps_orphan\n\toption enabled '0'\n\toption type 'remote'\n\toption nft_rules '1'\n`,
      `${UCI}/singbox-ui`,
    );
    expect((await apply()).exitCode).toBe(0);
    expect(await readApplied()).not.toContain("9.9.9.0/24");

    // 4) section deleted outright -> gone
    await putFile(GOOD_UCI + RS_SECTIONS, `${UCI}/singbox-ui`);
    expect((await apply()).exitCode).toBe(0);
    expect(await readApplied()).not.toContain("9.9.9.0/24");

    await exec(`rm -f ${RS_DIR}/rs_aps_orphan.json`);
  });

  it("S1-2: invalid tproxy listen_port (99999) makes apply FAIL loudly", async () => {
    const badUci = `config dns_server fakeip\n\toption type 'fakeip'\n\toption enabled '1'\n\toption inet4_range '198.18.0.0/15'\nconfig inbound tp\n\toption protocol 'tproxy'\n\toption enabled '1'\n\toption nft_rules '1'\n\toption listen_port '99999'\n\tlist interface 'br-lan'\n`;
    await putFile(badUci + RS_SECTIONS, `${UCI}/singbox-ui`);
    const r = await apply();
    expect(r.exitCode, "apply must FAIL for invalid listen_port").not.toBe(0);
    expect(r.stderr).toMatch(/invalid listen_port|tproxy/i);
    // restore good UCI for subsequent tests
    await putFile(GOOD_UCI + RS_SECTIONS, `${UCI}/singbox-ui`);
  });
});
