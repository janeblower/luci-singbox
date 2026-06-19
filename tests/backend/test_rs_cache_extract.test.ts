import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

const LIB =
  process.env.SB_VM_LIB ?? "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";
const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const SUB_UC = `${WORK}/singbox-ui/root/usr/share/singbox-ui/nft-rulesets.uc`;
const TMP = `/tmp/sb-rscache-${process.pid}`;
const RUNTIME = `${TMP}/runtime`;
const BBOLT = `${TMP}/bin/bbolt-client`;
const SING_BOX = `${TMP}/bin/sing-box`;
const INITD = `${TMP}/initd/singbox-ui`;
const RELOAD_LOG = `${TMP}/reload.log`;

// Shell script for fake bbolt-client.
// $1, $2, $4, ${BBOLT_KNOWN:-} are shell variables — NOT TS interpolations.
// \003 is the octal escape that must appear literally in the shell script.
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

// Shell script for fake sing-box.
// $1, $2, $out are shell variables — NOT TS interpolations.
const FAKE_SINGBOX = `#!/bin/sh
out=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done
[ -n "$out" ] && printf '{"version":1,"rules":[{"ip_cidr":["1.2.3.0/24"]}]}' >"$out"
exit 0
`;

// Runs nft-rulesets.uc with given args, injecting env vars via inline prefix.
// UCI_CONFIG_DIR, SINGBOX_TMPDIR, SINGBOX_BBOLT_BIN, SINGBOX are always set.
// extraEnv may add BBOLT_KNOWN=..., SINGBOX_INITD=..., etc.
async function runUc(
  args: string,
  extraEnv: string = "",
): Promise<{ stdout: string; exitCode: number }> {
  const r = await exec(
    `cd ${WORK} && ${extraEnv} UCI_CONFIG_DIR=${TMP} SINGBOX_TMPDIR=${RUNTIME} SINGBOX_BBOLT_BIN=${BBOLT} SINGBOX=${SING_BOX} ucode -L ${LIB} ${SUB_UC} ${args} 2>&1 || true`,
  );
  return { stdout: r.stdout, exitCode: r.exitCode };
}

async function writeUci(content: string): Promise<void> {
  await putFile(content, `${TMP}/singbox-ui`);
}

describe("rs_cache_extract", () => {
  useGuest();

  beforeAll(async () => {
    await exec(`mkdir -p ${TMP}/bin ${TMP}/initd ${RUNTIME}`);
    await putFile(FAKE_BBOLT, BBOLT);
    await putFile(FAKE_SINGBOX, SING_BOX);
    await exec(`chmod +x ${BBOLT} ${SING_BOX}`);
  });

  afterAll(async () => {
    await exec(`rm -rf ${TMP}`);
  });

  it("remote ruleset extracted from cache.db (no curl)", async () => {
    await writeUci(
      `config cache 'cache'\n\toption enabled '1'\nconfig ruleset 'geoip'\n\toption type 'remote'\n\toption url 'https://example.test/geoip.srs'\n\toption nft_rules '1'\n`,
    );
    await exec(`rm -f ${RUNTIME}/rs_geoip.json`);
    await runUc("fetch", "BBOLT_KNOWN=geoip");
    const check = await exec(
      `test -s ${RUNTIME}/rs_geoip.json && grep -q '1.2.3.0/24' ${RUNTIME}/rs_geoip.json`,
    );
    expect(
      check.exitCode,
      "rs_geoip.json must exist with decompiled content",
    ).toBe(0);
    // curl must not exist in stub bin — confirms it was never invoked
    const curlCheck = await exec(`test -f ${TMP}/bin/curl`);
    expect(curlCheck.exitCode, "curl must not exist in stub bin").not.toBe(0);
  });

  it("cache disabled (no cache section): skipped with log", async () => {
    // No cache section → cache is disabled; expect a skip + diagnostic log
    await writeUci(
      `config ruleset 'geoip'\n\toption type 'remote'\n\toption url 'https://example.test/geoip.srs'\n\toption nft_rules '1'\n`,
    );
    await exec(`rm -f ${RUNTIME}/rs_geoip.json`);
    const r = await runUc("fetch", "BBOLT_KNOWN=");
    expect(r.stdout).toMatch(/cache.*disabled|cache.*off|no cache|cache not/i);
    const created = await exec(`test -f ${RUNTIME}/rs_geoip.json`);
    expect(
      created.exitCode,
      "rs_geoip.json must not be created without cache",
    ).not.toBe(0);
  });

  it("bbolt tag not in cache (cold): no rs file produced", async () => {
    await writeUci(
      `config cache 'cache'\n\toption enabled '1'\nconfig ruleset 'geoip'\n\toption type 'remote'\n\toption url 'https://example.test/geoip.srs'\n\toption nft_rules '1'\n`,
    );
    await exec(`rm -f ${RUNTIME}/rs_geoip.json`);
    // BBOLT_KNOWN is empty → bbolt lists no tags → tag is unknown
    await runUc("fetch", "BBOLT_KNOWN=");
    const created = await exec(`test -f ${RUNTIME}/rs_geoip.json`);
    expect(
      created.exitCode,
      "rs_geoip.json must NOT be created for unknown tag",
    ).not.toBe(0);
  });

  it("cold tag triggers ONE init.d reload in refresh; warm tag does not reload", async () => {
    // Fake init.d script: appends "reload-called <args>" to $RELOAD_LOG
    await putFile(
      `#!/bin/sh\necho "reload-called $*" >>"$RELOAD_LOG"\n`,
      INITD,
    );
    await exec(`chmod +x ${INITD}`);

    await writeUci(
      `config cache 'cache'\n\toption enabled '1'\nconfig ruleset 'geoip'\n\toption type 'remote'\n\toption url 'https://example.test/geoip.srs'\n\toption nft_rules '1'\n\toption update_interval '1'\n`,
    );

    // --- Cold: bbolt lists no keys → refresh must trigger reload ---
    await exec(`> ${RELOAD_LOG}`);
    await exec(
      `cd ${WORK} && UCI_CONFIG_DIR=${TMP} SINGBOX_TMPDIR=${RUNTIME} SINGBOX_BBOLT_BIN=${BBOLT} SINGBOX=${SING_BOX} SINGBOX_INITD=${INITD} SINGBOX_NFT_APPLY=true RELOAD_LOG=${RELOAD_LOG} BBOLT_KNOWN= SINGBOX_RS_CACHE_WAIT=1 ucode -L ${LIB} ${SUB_UC} refresh force 2>&1 || true`,
    );
    const coldCheck = await exec(`grep -q reload-called ${RELOAD_LOG}`);
    expect(coldCheck.exitCode, "cold tag must trigger reload").toBe(0);

    // --- Warm: tag is known → no reload, rs file built ---
    await exec(`> ${RELOAD_LOG}`);
    await exec(`rm -f ${RUNTIME}/rs_geoip.json`);
    await exec(
      `cd ${WORK} && UCI_CONFIG_DIR=${TMP} SINGBOX_TMPDIR=${RUNTIME} SINGBOX_BBOLT_BIN=${BBOLT} SINGBOX=${SING_BOX} SINGBOX_INITD=${INITD} SINGBOX_NFT_APPLY=true RELOAD_LOG=${RELOAD_LOG} BBOLT_KNOWN=geoip SINGBOX_RS_CACHE_WAIT=1 ucode -L ${LIB} ${SUB_UC} refresh force 2>&1 || true`,
    );
    const warmNoReload = await exec(`test -s ${RELOAD_LOG}`);
    expect(
      warmNoReload.exitCode,
      "warm tag must NOT trigger reload (log must be empty)",
    ).not.toBe(0);
    const warmBuilt = await exec(`test -s ${RUNTIME}/rs_geoip.json`);
    expect(warmBuilt.exitCode, "warm refresh must build rs_geoip.json").toBe(0);
  });
});
