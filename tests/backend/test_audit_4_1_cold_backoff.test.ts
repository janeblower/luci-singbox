import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

// Port of tests/backend/test_audit_4_1_cold_backoff.sh
// Regression for audit S4-1 / S4-5 / S4-6 (nft-rulesets.uc cold rule-set reload):
//   4.1 HIGH — dead remote rule-set backoff sentinel prevents reload on every cron cycle
//   4.5 LOW  — wait_for_tags must bail (not busy-spin) when 'sleep' is unforkable
//   4.6 INFO — failed cache_extract_srs leaves no stray rs_*.raw
//   BUG1     — future-dated sentinel (NTP clock skew) must NOT wedge the tag
//   BUG2     — force-refresh overrides backoff; cron path (no force) does not
//   SEC-10   — bbolt probe failure (null keys) must NOT trigger a reload

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB =
  process.env.SB_VM_LIB ?? `${WORK}/singbox-ui/root/usr/share/singbox-ui/lib`;
const SUB_UC = `${WORK}/singbox-ui/root/usr/share/singbox-ui/nft-rulesets.uc`;
const TMP = `/tmp/sb-cb41-${process.pid}`;
const RUNTIME = `${TMP}/runtime`;
const BIN = `${TMP}/bin`;
const INITD = `${TMP}/initd`;
const RELOAD_LOG = `${TMP}/reload.log`;
const BBOLT = `${BIN}/bbolt-client`;
const SING_BOX = `${BIN}/sing-box`;
const INITD_SCRIPT = `${INITD}/singbox-ui`;

// Fake bbolt-client: lists $BBOLT_KNOWN on "db rule_set"; reads a body for
// known tags on "-r db rule_set <tag>"; exits 1 for unknown tags.
const FAKE_BBOLT = `#!/bin/sh
known=" \${BBOLT_KNOWN:-} "
if [ "$1" = "-r" ]; then
  tag="$4"
  case "$known" in *" $tag "*) printf 'SRS\\003FAKEBODY'; exit 0 ;; esac
  exit 1
fi
if [ "$2" = "rule_set" ]; then
  for t in \${BBOLT_KNOWN:-}; do echo "$t"; done
  exit 0
fi
exit 0
`;

// Fake sing-box: writes a minimal JSON rule-set to -o <outfile>.
const FAKE_SINGBOX = `#!/bin/sh
out=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done
[ -n "$out" ] && printf '{"version":1,"rules":[{"ip_cidr":["1.2.3.0/24"]}]}' >"$out"
exit 0
`;

// Fake init.d: records every reload call.
const FAKE_INITD = `#!/bin/sh
echo "reload-called $*" >> ${RELOAD_LOG}
`;

// Dead-tag UCI config (cache enabled, one remote ruleset with 1-day interval).
const UCI_DEAD = `config cache 'cache'
\toption enabled '1'
config ruleset 'deadrs'
\toption type 'remote'
\toption url 'https://example.invalid/dead.srs'
\toption nft_rules '1'
\toption update_interval '86400'
`;

async function setup(): Promise<void> {
  await exec(`mkdir -p ${RUNTIME} ${BIN} ${INITD} && > ${RELOAD_LOG}`);
  await putFile(FAKE_BBOLT, BBOLT);
  await putFile(FAKE_SINGBOX, SING_BOX);
  await putFile(FAKE_INITD, INITD_SCRIPT);
  await exec(`chmod +x ${BBOLT} ${SING_BOX} ${INITD_SCRIPT}`);
  await putFile(UCI_DEAD, `${TMP}/singbox-ui`);
}

async function teardown(): Promise<void> {
  await exec(`rm -rf ${TMP}`);
}

// Run nft-rulesets.uc with given args.
// extraEnv is prepended to the command as shell VAR=val pairs.
async function runUc(
  args: string,
  extraEnv: string = "",
): Promise<{ stdout: string; exitCode: number }> {
  const env = [
    `UCI_CONFIG_DIR=${TMP}`,
    `SINGBOX_TMPDIR=${RUNTIME}`,
    `SINGBOX_BBOLT_BIN=${BBOLT}`,
    `SINGBOX=${SING_BOX}`,
    `SINGBOX_INITD=${INITD_SCRIPT}`,
    `SINGBOX_NFT_APPLY=true`,
    `RELOAD_LOG=${RELOAD_LOG}`,
    `SINGBOX_RS_CACHE_WAIT=1`,
    extraEnv,
  ]
    .filter(Boolean)
    .join(" ");
  const r = await exec(
    `cd ${WORK} && export PATH=${BIN}:$PATH && ${env} ucode -L ${LIB} ${SUB_UC} ${args} >/dev/null 2>&1 || true`,
  );
  return { stdout: r.stdout, exitCode: r.exitCode };
}

async function countReloads(): Promise<number> {
  const r = await exec(
    `n=$(grep -c reload-called ${RELOAD_LOG} 2>/dev/null) || true; echo "\${n:-0}"`,
  );
  return parseInt(r.stdout.trim(), 10) || 0;
}

async function clearReloadLog(): Promise<void> {
  await exec(`> ${RELOAD_LOG}`);
}

describe("audit_4_1_cold_backoff (S4-1/S4-5/S4-6/BUG1/BUG2/SEC-10)", () => {
  useGuest();

  it("setup: create stubs and UCI", async () => {
    await setup();
    const r = await exec(`[ -x ${BBOLT} ] && echo ok || echo fail`);
    expect(r.stdout.trim()).toBe("ok");
  });

  // ---- 4.1: first refresh (no sentinel) → exactly 1 reload, stays cold ----
  it("4.1: first cron refresh (no sentinel) → exactly 1 reload", async () => {
    await clearReloadLog();
    await runUc("refresh");
    expect(await countReloads()).toBe(1);
  });

  // ---- 4.1: second + third within backoff window → NO reload ----
  it("4.1: second refresh inside backoff window → 0 reloads", async () => {
    await clearReloadLog();
    await runUc("refresh");
    expect(await countReloads()).toBe(0);
  });

  it("4.1: third refresh inside backoff window → 0 reloads", async () => {
    await clearReloadLog();
    await runUc("refresh");
    expect(await countReloads()).toBe(0);
  });

  // ---- 4.1: backdate sentinel past update_interval → eligible again ----
  it("4.1: after update_interval elapses, cold tag is retry-eligible", async () => {
    // Back-date the sentinel to far past (epoch 0 = 1970-01-01)
    await exec(`touch -t 197001010000 ${RUNTIME}/.rs_cold_deadrs.attempt`);
    await clearReloadLog();
    await runUc("refresh");
    expect(await countReloads()).toBe(1);
  });

  // ---- 4.1: warm tag NEVER reloads and clears stale sentinel ----
  it("4.1: warm tag does not reload; rebuilds set; clears sentinel", async () => {
    // Pre-plant a sentinel; warm tag must clear it
    await exec(`echo 123 > ${RUNTIME}/.rs_cold_deadrs.attempt`);
    await exec(`rm -f ${RUNTIME}/rs_deadrs.json`);
    await clearReloadLog();
    await runUc("refresh force", "BBOLT_KNOWN=deadrs");
    expect(await countReloads()).toBe(0);
    const r = await exec(
      `[ -s ${RUNTIME}/rs_deadrs.json ] && echo yes || echo no`,
    );
    expect(r.stdout.trim()).toBe("yes");
    const s = await exec(
      `[ -f ${RUNTIME}/.rs_cold_deadrs.attempt ] && echo yes || echo no`,
    );
    expect(s.stdout.trim()).toBe("no");
  });

  // ---- 4.1: cold tag that recovers becomes immediately eligible again ----
  it("4.1: cleared sentinel → cold tag eligible without full interval", async () => {
    // Warm extract above cleared the sentinel; go cold again
    await exec(`rm -f ${RUNTIME}/rs_deadrs.json`);
    await clearReloadLog();
    await runUc("refresh");
    expect(await countReloads()).toBe(1);
  });

  // ---- 4.6: failed cache extract leaves no stray rs_*.raw ----
  it("4.6: failed extract leaves no stray rs_deadrs.raw or temp sibling", async () => {
    await exec(`rm -f ${RUNTIME}/rs_deadrs.raw ${RUNTIME}/rs_deadrs.raw.tmp.*`);
    await runUc("fetch", "BBOLT_KNOWN= SINGBOX_BOOT_FETCH=1");
    const r1 = await exec(
      `[ -f ${RUNTIME}/rs_deadrs.raw ] && echo yes || echo no`,
    );
    expect(r1.stdout.trim()).toBe("no");
    const r2 = await exec(
      `ls ${RUNTIME}/rs_deadrs.raw.tmp.* 2>/dev/null | wc -l | tr -d ' '`,
    );
    expect(r2.stdout.trim()).toBe("0");
  });

  // ---- 4.5: wait_for_tags terminates when 'sleep' is unforkable ----
  it("4.5: wait_for_tags bails on broken sleep (terminates in ≤8s)", async () => {
    // Shadow sleep with a non-executable
    await putFile("#!/bin/sh\nexit 7\n", `${BIN}/sleep`);
    await exec(`chmod +x ${BIN}/sleep`);
    await exec(`rm -f ${RUNTIME}/.rs_cold_deadrs.attempt`);
    await clearReloadLog();
    const start = Date.now();
    await runUc("refresh", "SINGBOX_RS_CACHE_WAIT=5");
    const elapsed = (Date.now() - start) / 1000;
    expect(elapsed).toBeLessThanOrEqual(8);
    // Restore real sleep
    await exec(`rm -f ${BIN}/sleep`);
  });

  // ---- 4.1 BUG1: future-dated sentinel does NOT wedge the tag ----
  it("BUG1: future-dated sentinel treated as elapsed → 1 reload", async () => {
    await exec(`rm -f ${RUNTIME}/rs_deadrs.json`);
    // Stamp sentinel far into the future (2035-01-01, <2038 for 32-bit safety)
    await exec(`touch -t 203501010000 ${RUNTIME}/.rs_cold_deadrs.attempt`);
    await clearReloadLog();
    await runUc("refresh");
    expect(await countReloads()).toBe(1);
  });

  // ---- 4.1 BUG2: force overrides backoff; cron (no force) does not ----
  it("BUG2(a): cron refresh inside backoff window → 0 reloads", async () => {
    // Stamp a fresh sentinel (mtime = now)
    await exec(
      `date +%s > ${RUNTIME}/.rs_cold_deadrs.attempt && touch ${RUNTIME}/.rs_cold_deadrs.attempt`,
    );
    await clearReloadLog();
    await runUc("refresh");
    expect(await countReloads()).toBe(0);
  });

  it("BUG2(b): force-refresh overrides backoff window → 1 reload", async () => {
    // Same fresh sentinel from above
    await clearReloadLog();
    await runUc("refresh force");
    expect(await countReloads()).toBe(1);
  });

  // ---- SEC-10: bbolt probe failure (null key list) must NOT trigger reload ----
  it("SEC-10: null key list (missing bbolt binary) → 0 reloads even on force", async () => {
    await exec(`rm -f ${RUNTIME}/.rs_cold_deadrs.attempt`);
    await clearReloadLog();
    await runUc("refresh force", `SINGBOX_BBOLT_BIN=${BIN}/does-not-exist`);
    expect(await countReloads()).toBe(0);
  });

  it("teardown", async () => {
    await teardown();
  });
});
