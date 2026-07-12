import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

// Regression for audit S4-1 / S4-5 / S4-6 (nft-rulesets.uc cold rule-set reload):
//   4.1 HIGH — dead remote rule-set backoff sentinel prevents reload on every cron cycle
//   4.5 LOW  — wait_for_tags must bail (not busy-spin) when 'sleep' is unforkable
//   4.6 INFO — failed cache_extract_srs leaves no stray rs_*.raw
//   BUG1     — future-dated sentinel (NTP clock skew) must NOT wedge the tag
//   BUG2     — force-refresh overrides backoff; cron path (no force) does not
//   SEC-10   — cache probe FAILURE (null keys) must NOT trigger a reload
//   NOBUCKET — a readable cache.db with no rule_set bucket is NOT a probe
//              failure: it is confirmed evidence the tags are cold → reload
//   POSTPROBE— a probe that fails AFTER the reload we already issued must still
//              arm the backoff sentinel, or S4-1's reload loop comes back

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB =
  process.env.SB_VM_LIB ?? `${WORK}/singbox-ui/root/usr/share/singbox-ui/lib`;
const SUB_UC = `${WORK}/singbox-ui/root/usr/share/singbox-ui/nft-rulesets.uc`;
const TMP = `/tmp/sb-cb41-${process.pid}`;
const RUNTIME = `${TMP}/runtime`;
const BIN = `${TMP}/bin`;
const INITD = `${TMP}/initd`;
const FAKELIB = `${TMP}/fakelib`;
const RELOAD_LOG = `${TMP}/reload.log`;
const SING_BOX = `${BIN}/sing-box`;
const INITD_SCRIPT = `${INITD}/singbox-ui`;
// A real bbolt db with buckets a_empty..f_bytes and NO rule_set bucket.
const NO_BUCKET_DB = `${WORK}/bbolt-client/testdata/stress.db`;
const MISSING_DB = `${TMP}/no-such-cache.db`;

// Fake bbolt MODULE (not a binary): dropped into a lib dir passed to ucode
// BEFORE the real lib, so require("bbolt") resolves here while require("helpers")
// still reaches the real lib (ucode searches -L dirs in order). nft-rulesets.uc
// now reads cache.db in-process, so the seam is a module, not a forked CLI.
// $BBOLT_KNOWN keeps its old meaning — the space-separated set of tags in cache.db.
//
// $BBOLT_FAIL_FROM=N makes read_db throw from its Nth call onward (1-based), the
// way the real reader does on an unreadable cache.db. The module is required once
// per ucode process, so this counter spans a whole refresh — which is what lets a
// single run have its PRE-reload probe succeed and every probe AFTER the reload
// fail (POSTPROBE below). Unset/0 = never fail, so every other case is unchanged.
const FAKE_BBOLT_UC = `// test fake for lib/bbolt.uc
let known = [];
for (let t in split(getenv("BBOLT_KNOWN") ?? "", " ")) if (length(t)) push(known, t);
let fail_from = +(getenv("BBOLT_FAIL_FROM") ?? "0");
let reads = 0;
return {
	read_db:        function(p) {
	                    reads++;
	                    if (fail_from > 0 && reads >= fail_from) die("empty database");
	                    return { fake: true }; },
	page_size:      function(m) { return 4096; },
	select_root:    function(m, ps) { return 0; },
	find_bucket:    function(m, ps, root, name) { return (name == "rule_set") ? { page: 1 } : null; },
	page:           function(m, ps, n) { return "fake"; },
	walk:           function(m, ps, bp, buckets_only, depth, acc) {
	                    for (let k in known) push(acc, k); },
	search:         function(m, ps, bp, key, depth) {
	                    for (let k in known) if (k == key) return [ 0, "SRS\\x03FAKEBODY" ];
	                    return null; },
	unwrap_ruleset: function(v) { return "FAKEBODY"; },
};
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
// cacheDb=null keeps the default storage (ram → /tmp/singbox-ui-cache.db), which
// the fake module never actually opens; the real-module cases below point it at a
// concrete file via storage=custom.
function uciDead(cacheDb: string | null = null): string {
  const cache = cacheDb
    ? `config cache 'cache'\n\toption enabled '1'\n\toption storage 'custom'\n\toption path '${cacheDb}'\n`
    : `config cache 'cache'\n\toption enabled '1'\n`;
  return `${cache}config ruleset 'deadrs'
\toption type 'remote'
\toption url 'https://example.invalid/dead.srs'
\toption nft_rules '1'
\toption update_interval '86400'
`;
}

async function setup(): Promise<void> {
  await exec(
    `mkdir -p ${RUNTIME} ${BIN} ${INITD} ${FAKELIB} && > ${RELOAD_LOG}`,
  );
  await putFile(FAKE_BBOLT_UC, `${FAKELIB}/bbolt.uc`);
  await putFile(FAKE_SINGBOX, SING_BOX);
  await putFile(FAKE_INITD, INITD_SCRIPT);
  await exec(`chmod +x ${SING_BOX} ${INITD_SCRIPT}`);
  await putFile(uciDead(), `${TMP}/singbox-ui`);
}

async function teardown(): Promise<void> {
  await exec(`rm -rf ${TMP}`);
}

// Run nft-rulesets.uc with given args. extraEnv is prepended as shell VAR=val
// pairs. `fake` (default) prepends -L FAKELIB so require("bbolt") resolves to the
// fake module; pass false to drive the REAL reader against a real cache.db.
async function runUc(
  args: string,
  extraEnv: string = "",
  fake: boolean = true,
): Promise<{ stdout: string; exitCode: number }> {
  const env = [
    `UCI_CONFIG_DIR=${TMP}`,
    `SINGBOX_TMPDIR=${RUNTIME}`,
    `SINGBOX=${SING_BOX}`,
    `SINGBOX_INITD=${INITD_SCRIPT}`,
    `SINGBOX_NFT_APPLY=true`,
    `RELOAD_LOG=${RELOAD_LOG}`,
    `SINGBOX_RS_CACHE_WAIT=1`,
    extraEnv,
  ]
    .filter(Boolean)
    .join(" ");
  const libs = fake ? `-L ${FAKELIB} -L ${LIB}` : `-L ${LIB}`;
  const r = await exec(
    `cd ${WORK} && export PATH=${BIN}:$PATH && ${env} ucode ${libs} ${SUB_UC} ${args} 2>&1 || true`,
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
    const r = await exec(`[ -f ${FAKELIB}/bbolt.uc ] && echo ok || echo fail`);
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

  // ---- SEC-10: a FAILED cache probe must NOT trigger a reload ----------------
  // Real bbolt module, cache.db path that does not exist: read_db fails, the probe
  // returns null, and a failed probe must never bounce the daemon — not even on a
  // forced refresh, and not even if the tags were in fact warm.
  //
  // (The old wording — "null key list (missing bbolt binary)" — described a fork
  // that no longer happens: nft-rulesets.uc reads cache.db in-process, so there is
  // no binary to be missing. An unreadable/absent cache.db is the failure mode that
  // actually reaches production.)
  it("SEC-10: unreadable cache.db → 0 reloads even on force", async () => {
    await putFile(uciDead(MISSING_DB), `${TMP}/singbox-ui`);
    await exec(`rm -f ${MISSING_DB} ${RUNTIME}/.rs_cold_deadrs.attempt`);
    await exec(`rm -f ${RUNTIME}/rs_deadrs.json`);
    await clearReloadLog();
    const r = await runUc("refresh force", "", /* fake */ false);
    expect(r.stdout).toContain("cache probe failed");
    expect(await countReloads()).toBe(0);
  });

  // ---- NOBUCKET: a readable db with no rule_set bucket is COLD, not a failure --
  // The counterpart to SEC-10, and the reason cache_open() cannot fold "no bucket"
  // into its null (= probe failed) return. sing-box creates the rule_set bucket
  // lazily, on the first rule-set it caches — so a router whose only nft rule-set
  // has a dead/typo'd URL has a perfectly readable cache.db with NO rule_set
  // bucket. That is confirmed evidence the tag is cold (the exact S4-1 scenario),
  // and the operator fixing the URL and hitting Refresh must still get a reload.
  // Folding it into the null probe would defer that reload forever.
  //
  // Driven against the REAL reader: the fake module's find_bucket always answers
  // rule_set, so it structurally cannot express this shape.
  it("NOBUCKET: readable cache.db without a rule_set bucket → cold → 1 reload", async () => {
    await putFile(uciDead(NO_BUCKET_DB), `${TMP}/singbox-ui`);
    await exec(`test -f ${NO_BUCKET_DB}`); // fixture must exist
    await exec(
      `rm -f ${RUNTIME}/.rs_cold_deadrs.attempt ${RUNTIME}/rs_deadrs.json`,
    );
    await clearReloadLog();
    const r = await runUc("refresh force", "", /* fake */ false);
    expect(r.stdout).not.toContain("cache probe failed");
    expect(await countReloads()).toBe(1);
  });

  // ---- POSTPROBE: a probe that fails AFTER the reload must still arm the backoff --
  // SEC-10 says a failed probe must not TRIGGER a reload. Its mirror image: once a
  // reload HAS been issued, a failed post-wait probe must not be read as "the tag
  // went warm" either — it means we cannot tell, and the backoff sentinel has to be
  // written regardless. Otherwise the tag stays retry-eligible and the very next
  // cron cycle issues another init.d reload — the un-throttled sing-box stop+start
  // loop S4-1 exists to prevent, dropping every live proxy connection every 15
  // minutes, forever.
  //
  // Reachable because cache.db is re-read from scratch at each probe: read_db slurps
  // a multi-MB file into RAM on a 64 MB router, so a transient allocation/IO failure
  // (or flaky flash under storage=flash) makes the POST probe fail while the PRE one
  // succeeded. The forked shim could not express this: popen swallowed its exit
  // status, so an unreadable db came back as an empty {} and the sentinel always got
  // written. Classifying the failure honestly as null is what silently dropped it.
  //
  // BBOLT_FAIL_FROM=2: read_db succeeds on call 1 (the pre-reload probe → cold →
  // eligible → reload) and throws from call 2 on (wait_for_tags, the post-wait probe,
  // and cmd_fetch_rulesets' open — whose log line proves the seam actually fired).
  it("POSTPROBE: failed post-reload probe still records the sentinel", async () => {
    await putFile(uciDead(), `${TMP}/singbox-ui`); // back to the fake-module cache
    await exec(
      `rm -f ${RUNTIME}/.rs_cold_deadrs.attempt ${RUNTIME}/rs_deadrs.json`,
    );
    await clearReloadLog();
    const r = await runUc(
      "refresh",
      "BBOLT_KNOWN= BBOLT_FAIL_FROM=2 SINGBOX_RS_CACHE_WAIT=0",
    );
    // pre-reload probe read fine → cold tag → eligible → exactly one reload
    expect(await countReloads()).toBe(1);
    // and every probe after it failed (not merely "no tags") — the seam fired
    expect(r.stdout).toContain("cache.db unreadable: empty database");
    const s = await exec(
      `[ -f ${RUNTIME}/.rs_cold_deadrs.attempt ] && echo yes || echo no`,
    );
    expect(s.stdout.trim()).toBe("yes"); // regression: was "no" → reload loop
  });

  it("POSTPROBE: the next cron refresh is throttled by that sentinel → 0 reloads", async () => {
    // Cache readable again, tag still cold: only the sentinel written above stands
    // between us and a second stop+start. Without it this reloads every cycle.
    await exec(`rm -f ${RUNTIME}/rs_deadrs.json`); // keep the tag stale, keep the sentinel
    await clearReloadLog();
    const r = await runUc("refresh", "BBOLT_KNOWN=");
    expect(r.stdout).toContain("not in cache.db yet"); // reached the cold path
    expect(await countReloads()).toBe(0);
  });

  it("teardown", async () => {
    await teardown();
  });
});
