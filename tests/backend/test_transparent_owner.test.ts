import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

// Exactly ONE thing may own the transparent path (system routing / the firewall):
//   tproxy.nft_rules — our `inet singbox_ui` table + the ip rule
//   tun.auto_route   — sing-box's own policy routing (auto_redirect rides on it
//                      and installs sing-box's OWN nft rules, fw4 compat included)
// A tun with auto_route OFF intercepts nothing, so it does not compete.
//
// `sing-box check` cannot catch a double claim — both configs are individually
// valid — so this invariant is ours to guard: generate.uc refuses to build, and
// init.d refuses to start the daemon on the stale config left behind.
//
// The UI disables the loser's checkbox, so reaching the conflict means someone
// hand-edited UCI. Both entrypoints are exercised through the PROD path here
// (argv-invoked generate.uc, sourced init.d), never `ucode -L lib`.

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB = `${WORK}/singbox-ui/root/usr/share/singbox-ui/lib`;
const GENERATE_UC = `${WORK}/singbox-ui/root/usr/share/singbox-ui/generate.uc`;
const INIT = `${WORK}/singbox-ui/root/etc/init.d/singbox-ui`;

const TPROXY = `
config inbound 'tp_in'
\toption enabled '1'
\toption protocol 'tproxy'
\toption listen_port '7893'
\toption nft_rules '1'
`;

// tun without auto_route: a plain netdev, no claim on system routing.
function tun(autoRoute: string | null): string {
  return `
config inbound 'tun_in'
\toption enabled '1'
\toption protocol 'tun'
\tlist address '172.19.0.1/30'
${autoRoute === null ? "" : `\toption auto_route '${autoRoute}'\n`}`;
}

const SENTINEL = '{"sentinel":"last known good"}';

type Gen = { rc: number; stderr: string; config: string };

// Run generate.uc exactly as init.d/rpcd do (argv + env), against a throwaway
// UCI dir, with a sentinel already sitting at SINGBOX_CONFIG: a refusal must
// leave it byte-for-byte intact.
async function generate(uciBody: string): Promise<Gen> {
  const dir = `/tmp/towner_${process.pid}_${Math.random().toString(36).slice(2)}`;
  const out = `${dir}/singbox-ui.json`;
  await exec(`mkdir -p ${dir}/subs`);
  await putFile(uciBody, `${dir}/singbox-ui`);
  await putFile(SENTINEL, out);

  const r = await exec(
    `cd ${WORK} && UCI_CONFIG_DIR=${dir} SINGBOX_TMPDIR=${dir}/subs SINGBOX_CONFIG=${out} ` +
      `ucode -L ${LIB} ${GENERATE_UC}; echo "RC=$?"; cat ${out}; rm -rf ${dir}`,
  );
  const m = r.stdout.match(/RC=(\d+)/);
  return {
    rc: m ? Number(m[1]) : -1,
    stderr: r.stderr,
    config: r.stdout.replace(/[\s\S]*?RC=\d+\n/, ""),
  };
}

describe("transparent path ownership (tproxy.nft_rules vs tun.auto_route)", () => {
  useGuest();

  it("tproxy alone (nft_rules) generates", async () => {
    const g = await generate(TPROXY);
    expect(g.rc).toBe(0);
    expect(g.config).toContain('"type": "tproxy"');
  });

  it("tun alone (auto_route=1) generates", async () => {
    const g = await generate(tun("1"));
    expect(g.rc).toBe(0);
    expect(g.config).toContain('"auto_route": true');
  });

  it("tproxy + tun(auto_route=1): refuses, names both, keeps the old config", async () => {
    const g = await generate(TPROXY + tun("1"));
    // rc 3 = EXIT_TRANSPARENT_CONFLICT (generate.uc). init.d's __do_start
    // now refuses to start on THIS specific code and falls through to its
    // existing guards for every other non-zero rc (see the write-failure
    // regression below) — so the exact value is load-bearing, not just
    // "non-zero".
    expect(g.rc).toBe(3);
    expect(g.stderr).toContain("tp_in");
    expect(g.stderr).toContain("tun_in");
    // The last known-good config must survive untouched — the daemon is still
    // running on it.
    expect(g.config).toBe(SENTINEL);
  });

  it("tproxy + tun(auto_route=0) is NOT a conflict", async () => {
    const g = await generate(TPROXY + tun("0"));
    expect(g.rc).toBe(0);
  });

  // Polarity guard. tun.auto_route has `default: 0` (commit 61534499): LuCI
  // DELETES an option whose value equals its default, so a default of 1 made a
  // ticked box vanish from UCI and the tun emitted no auto_route at all. Unset
  // therefore means OFF — for emission, for `requires`, and for ownership alike.
  // If someone "fixes" the predicate to `auto_route !== "0"` (the polarity that
  // is right for tproxy.nft_rules, whose default IS 1 and which is never
  // emitted), this dead tun would claim ownership, switch tproxy's nft rules off
  // and leave the box with no interception at all. This test is what stops that.
  it("tproxy + tun with auto_route UNSET is NOT a conflict (unset = OFF)", async () => {
    const g = await generate(TPROXY + tun(null));
    expect(g.rc).toBe(0);
    expect(g.config).toContain('"type": "tproxy"');
    expect(g.config).not.toContain("auto_route");
  });
});

// init.d must honour the generator's exit code — but ONLY the conflict's
// specific rc (3). Without this check procd starts the daemon on the STALE
// /tmp/singbox-ui.json and "we refuse to start" is a lie: the operator's edit
// is silently discarded and we report success.
// STATEFUL (touches /tmp/singbox-ui.json) — bun runs test files serially.
describe("init.d refuses to start on a generator conflict refusal (rc 3)", () => {
  useGuest();
  let TD = "";

  beforeAll(async () => {
    TD = (await exec("mktemp -d")).stdout.trim();
    await exec(`mkdir -p '${TD}/bin'`);
    for (const [name, body] of [
      ["uci", "#!/bin/sh\nexit 1\n"],
      ["logger", `#!/bin/sh\necho "logger $*" >>"${TD}/logger.log"\n`],
      ["sing-box", `#!/bin/sh\necho "sing-box $*" >>"${TD}/singbox.log"\n`],
      [
        "procd_open_instance",
        `#!/bin/sh\necho "open $*" >>"${TD}/procd.log"\n`,
      ],
      ["procd_set_param", "#!/bin/sh\n:\n"],
      ["procd_close_instance", "#!/bin/sh\n:\n"],
      // generate.uc refuses with rc 3 (EXIT_TRANSPARENT_CONFLICT) and, like
      // the real one, leaves the previous config in place; everything else
      // succeeds.
      [
        "ucode",
        `#!/bin/sh
for _arg in "$@"; do
  case "$_arg" in
    */generate.uc) echo "generate: refusing to build" 1>&2; exit 3 ;;
  esac
done
exit 0
`,
      ],
    ] as [string, string][]) {
      await putFile(body, `${TD}/bin/${name}`);
      await exec(`chmod +x '${TD}/bin/${name}'`);
    }
    await exec(
      `touch '${TD}/logger.log' '${TD}/procd.log' '${TD}/singbox.log'`,
    );
  });

  afterAll(async () => {
    await exec(
      `rm -rf '${TD}' /tmp/singbox-ui/.lifecycle.lock /tmp/singbox-ui.json`,
    );
  });

  it("start_service fails and does not hand the stale config to procd", async () => {
    await putFile(SENTINEL, "/tmp/singbox-ui.json");
    const r = await exec(
      `PATH="${TD}/bin:$PATH" SINGBOX_BIN="${TD}/bin/sing-box" sh -c "
        . '${INIT}'
        start_service
      "`,
    );
    expect(r.exitCode).toBe(1); // __do_start's `return 1` on the refusal path

    const logger = (await exec(`cat '${TD}/logger.log'`)).stdout;
    const procd = (await exec(`cat '${TD}/procd.log'`)).stdout;
    const singbox = (await exec(`cat '${TD}/singbox.log'`)).stdout;
    expect(logger).toContain("refusing to start");
    expect(procd).toBe(""); // no instance handed to procd
    expect(singbox).toBe(""); // not even a `check` on the stale config
    // and the stale config is still there, untouched
    expect((await exec("cat /tmp/singbox-ui.json")).stdout).toBe(SENTINEL);
  });
});

// THE REGRESSION (c29d4d2f): init.d used to refuse to start on ANY non-zero
// generate.uc rc, including the pre-existing "config write FAILED —
// CONTINUING ON PREVIOUS config (running stale)" path (also exit(1), see
// generate.uc's publish_atomic caller). That path exists so a transient write
// failure (disk pressure/ENOSPC) does NOT take sing-box down: the old,
// perfectly good /tmp/singbox-ui.json is still sitting there. A */15 cron
// reload (both cron jobs call `<init> reload` -> stop then start) hitting a
// write hiccup used to leave the router with NO proxy at all until the next
// cron run — over a transient disk blip. Fixed by giving the ownership
// conflict its own rc (3, EXIT_TRANSPARENT_CONFLICT); every other rc now
// falls through to init.d's pre-existing guards.
describe("write_failed_stale: a non-conflict generator failure keeps the previous config running", () => {
  useGuest();

  // generate.uc-level proof: a real write failure with a usable previous
  // config exits something OTHER than the conflict code, and leaves that
  // config byte-for-byte intact. Seam: a bind mount of the output directory
  // onto itself, remounted read-only, blocks fs.open(tmp, "w") at the VFS
  // level (EROFS) WITHOUT touching the file already sitting there — a mount
  // flag applies even to root, unlike chmod (root has CAP_DAC_OVERRIDE and
  // would sail through a permission bit). This is the exact same
  // "fs.open() fails, returns null" branch test_generate.test.ts already
  // covers via a nonexistent directory ("atomic publish: no tmp leak when
  // cannot open tmpfile") — just with a real CONFIG_OUT underneath this time,
  // which is the point: does a PRE-EXISTING good config survive.
  //
  // (`ulimit -f` + `trap '' XFSZ` was tried first, since rpcd's run_bg()
  // already leans on ignoring a signal so a child doesn't die outright. It
  // doesn't work here: ucode's fs write path silently swallows the EFBIG —
  // f.write() and f.close() both report success while the file is actually
  // truncated to 0 bytes on disk — so rc came back 0. Verified interactively
  // against a kept-alive guest; not a fragile assumption.)
  it("generate.uc: a write failure with a usable previous config does not exit the conflict code, and leaves the old config untouched", async () => {
    const dir = `/tmp/twfs_${process.pid}_${Math.random().toString(36).slice(2)}`;
    const out = `${dir}/singbox-ui.json`;
    await exec(`mkdir -p ${dir}/subs ${dir}/ucidir`);
    await putFile(TPROXY, `${dir}/ucidir/singbox-ui`);
    await putFile(SENTINEL, out);
    await exec(`mount --bind ${dir} ${dir} && mount -o remount,bind,ro ${dir}`);

    let r: { stdout: string };
    try {
      r = await exec(
        `cd ${WORK} && UCI_CONFIG_DIR=${dir}/ucidir SINGBOX_TMPDIR=${dir}/subs SINGBOX_CONFIG=${out} ` +
          `ucode -L ${LIB} ${GENERATE_UC}; echo "RC=$?"; cat ${out}`,
      );
    } finally {
      await exec(`umount ${dir}`);
      await exec(`rm -rf ${dir}`);
    }
    const m = r.stdout.match(/RC=(\d+)/);
    const rc = m ? Number(m[1]) : -1;
    const config = r.stdout.replace(/[\s\S]*?RC=\d+\n/, "");

    expect(rc).not.toBe(0);
    expect(rc).not.toBe(3); // NOT EXIT_TRANSPARENT_CONFLICT
    expect(config).toBe(SENTINEL); // old good config survives, untouched
  });

  // init.d-level proof — this is the actual regression. A generator rc that
  // is non-zero but NOT the conflict code must fall through to __do_start's
  // existing guards ([ ! -s ... ] + `sing-box check`) and START the daemon
  // on the stale-but-valid config, instead of refusing outright.
  describe("init.d", () => {
    useGuest();
    let TD = "";

    beforeAll(async () => {
      TD = (await exec("mktemp -d")).stdout.trim();
      await exec(`mkdir -p '${TD}/bin'`);
      for (const [name, body] of [
        ["uci", "#!/bin/sh\nexit 1\n"],
        ["logger", `#!/bin/sh\necho "logger $*" >>"${TD}/logger.log"\n`],
        ["sing-box", `#!/bin/sh\necho "sing-box $*" >>"${TD}/singbox.log"\n`],
        [
          "procd_open_instance",
          `#!/bin/sh\necho "open $*" >>"${TD}/procd.log"\n`,
        ],
        ["procd_set_param", "#!/bin/sh\n:\n"],
        ["procd_close_instance", "#!/bin/sh\n:\n"],
        // generate.uc's write-failure path: rc 1 — NOT rc 3, the conflict's
        // code — and, exactly like the real publish_atomic, never touches
        // the existing /tmp/singbox-ui.json.
        [
          "ucode",
          `#!/bin/sh
for _arg in "$@"; do
  case "$_arg" in
    */generate.uc) echo "generate: config write FAILED — CONTINUING ON PREVIOUS config (running stale)" 1>&2; exit 1 ;;
  esac
done
exit 0
`,
        ],
      ] as [string, string][]) {
        await putFile(body, `${TD}/bin/${name}`);
        await exec(`chmod +x '${TD}/bin/${name}'`);
      }
      await exec(
        `touch '${TD}/logger.log' '${TD}/procd.log' '${TD}/singbox.log'`,
      );
    });

    afterAll(async () => {
      await exec(
        `rm -rf '${TD}' /tmp/singbox-ui/.lifecycle.lock /tmp/singbox-ui.json`,
      );
    });

    it("start_service starts sing-box on the previous config instead of refusing", async () => {
      await putFile(SENTINEL, "/tmp/singbox-ui.json");
      const r = await exec(
        `PATH="${TD}/bin:$PATH" SINGBOX_BIN="${TD}/bin/sing-box" sh -c "
          . '${INIT}'
          start_service
        "`,
      );
      expect(r.exitCode).toBe(0);

      const procd = (await exec(`cat '${TD}/procd.log'`)).stdout;
      const singbox = (await exec(`cat '${TD}/singbox.log'`)).stdout;
      // sing-box check ran on the stale-but-valid file, and the instance was
      // handed to procd — the fix under test.
      expect(singbox).toContain("check");
      expect(procd).not.toBe("");
      // and the stale config is still there, untouched
      expect((await exec("cat /tmp/singbox-ui.json")).stdout).toBe(SENTINEL);
    });
  });
});

// `generate.uc check-conflict` — the conflict guard, and NOTHING else. It exists
// so init.d's reload_service can ask the question BEFORE it stops the daemon
// (see the describe below) without a second copy of the predicate: same file,
// same helpers.transparent_conflict, same rc.
describe("generate.uc check-conflict: the guard alone, same rc", () => {
  useGuest();

  async function checkConflict(uciBody: string): Promise<Gen> {
    const dir = `/tmp/tcc_${process.pid}_${Math.random().toString(36).slice(2)}`;
    const out = `${dir}/singbox-ui.json`;
    await exec(`mkdir -p ${dir}/subs`);
    await putFile(uciBody, `${dir}/singbox-ui`);
    await putFile(SENTINEL, out);

    const r = await exec(
      `cd ${WORK} && UCI_CONFIG_DIR=${dir} SINGBOX_TMPDIR=${dir}/subs SINGBOX_CONFIG=${out} ` +
        `ucode -L ${LIB} ${GENERATE_UC} check-conflict; echo "RC=$?"; cat ${out}; rm -rf ${dir}`,
    );
    const m = r.stdout.match(/RC=(\d+)/);
    return {
      rc: m ? Number(m[1]) : -1,
      stderr: r.stderr,
      config: r.stdout.replace(/[\s\S]*?RC=\d+\n/, ""),
    };
  }

  it("conflict: rc 3 (EXIT_TRANSPARENT_CONFLICT), names both sections", async () => {
    const g = await checkConflict(TPROXY + tun("1"));
    expect(g.rc).toBe(3);
    expect(g.stderr).toContain("tp_in");
    expect(g.stderr).toContain("tun_in");
  });

  it("no conflict: rc 0 and it builds NOTHING (check-only)", async () => {
    const g = await checkConflict(TPROXY);
    expect(g.rc).toBe(0);
    // The sentinel is untouched: the mode exits before any building/publishing.
    // (Plain `generate.uc` on the same UCI would have overwritten it.)
    expect(g.config).toBe(SENTINEL);
  });
});

// THE BUG (this whole describe is the regression guard): reload_service used to
// be `stop; start`. `stop` removes our `inet singbox_ui` table; `start` then ran
// generate.uc, got rc 3 and refused. Net result on a conflicting UCI: no daemon,
// no nft table — the LAN egresses UNPROXIED. And every reload path lands here:
// both */15 cron jobs and the UI's Apply. Verified live on the dev stand before
// the fix: `nft list tables` went empty and sing-box was gone.
//
// The fix asks the question BEFORE stop and aborts the reload, leaving the
// daemon (and its table) serving the last known-good config. Boot is different —
// there is nothing to preserve there, so start_service still refuses (above).
describe("init.d reload_service: a conflict must not tear down the firewall", () => {
  useGuest();
  let TD = "";

  // ucodeStub: `$1` is the rc for `generate.uc check-conflict`, `$2` for every
  // other generate.uc call. Every invocation is logged, so the test can prove
  // `nftables.uc remove` (what `stop` does to our table) never ran.
  function ucodeStub(checkRc: number, genRc: number): string {
    return `#!/bin/sh
echo "ucode $*" >>"${TD}/ucode.log"
for _arg in "$@"; do
  case "$_arg" in
    check-conflict) exit ${checkRc} ;;
  esac
done
for _arg in "$@"; do
  case "$_arg" in
    */generate.uc) exit ${genRc} ;;
  esac
done
exit 0
`;
  }

  // Source the real init.d, then stub rc.common's `stop`/`start` (they are NOT
  // defined when the file is merely sourced) so we can see whether the entry
  // point called them at all. `entry` is reload_service or restart — rc.common's
  // `restart` is a bare `stop; start` with no hook, so init.d overrides it and
  // routes it through reload_service; the rpcd `restart` method (the UI's
  // "Restart service" button) had the identical teardown hole.
  async function reload(
    checkRc: number,
    genRc: number,
    entry = "reload_service",
  ) {
    await putFile(ucodeStub(checkRc, genRc), `${TD}/bin/ucode`);
    await exec(`chmod +x '${TD}/bin/ucode'`);
    await exec(`: > '${TD}/logger.log'; : > '${TD}/ucode.log'`);
    const r = await exec(
      `PATH="${TD}/bin:$PATH" sh -c "
        . '${INIT}'
        stop()  { echo stop  >>'${TD}/lifecycle.log'; }
        start() { echo start >>'${TD}/lifecycle.log'; }
        : > '${TD}/lifecycle.log'
        ${entry}
      "`,
    );
    return {
      rc: r.exitCode,
      lifecycle: (await exec(`cat '${TD}/lifecycle.log'`)).stdout,
      logger: (await exec(`cat '${TD}/logger.log'`)).stdout,
      ucode: (await exec(`cat '${TD}/ucode.log'`)).stdout,
      locked:
        (await exec("test -d /tmp/singbox-ui/.lifecycle.lock")).exitCode === 0,
    };
  }

  beforeAll(async () => {
    TD = (await exec("mktemp -d")).stdout.trim();
    await exec(`mkdir -p '${TD}/bin'`);
    await putFile(
      `#!/bin/sh\necho "logger $*" >>"${TD}/logger.log"\n`,
      `${TD}/bin/logger`,
    );
    await exec(`chmod +x '${TD}/bin/logger'`);
    await exec(
      `touch '${TD}/logger.log' '${TD}/ucode.log' '${TD}/lifecycle.log'`,
    );
  });

  afterAll(async () => {
    await exec(`rm -rf '${TD}' /tmp/singbox-ui/.lifecycle.lock`);
  });

  it("conflict: does NOT stop the daemon, fails the reload, says what to turn off", async () => {
    const r = await reload(3, 3);
    expect(r.lifecycle).toBe(""); // neither stop NOR start ran
    expect(r.ucode).not.toContain("remove"); // our nft table was never removed
    expect(r.rc).not.toBe(0);
    expect(r.logger).toContain("refusing to reload");
    expect(r.logger).toContain("nft_rules");
    expect(r.logger).toContain("auto_route");
    expect(r.locked).toBe(false); // the lifecycle lock is released on this path too
  });

  it("no conflict: normal stop + start", async () => {
    const r = await reload(0, 0);
    expect(r.lifecycle).toBe("stop\nstart\n");
    expect(r.rc).toBe(0);
    expect(r.locked).toBe(false);
  });

  // Fail OPEN on the check itself: a checker that dies for an unrelated reason
  // (ucode gone, a require() blowing up) must not become a broken reload. ONLY
  // rc 3 means "this config must not be used" — the same distinction 1b8c0914
  // drew for __do_start.
  it("a check that fails for another reason (rc 1) does NOT block the reload", async () => {
    const r = await reload(1, 0);
    expect(r.lifecycle).toBe("stop\nstart\n");
    expect(r.rc).toBe(0);
  });

  // `restart` is the SAME hole through a different door — the rpcd `restart`
  // method behind the UI's "Restart service" button. rc.common's `restart` is a
  // hardcoded `stop; start` (no `restart_service` hook, and the USE_PROCD block
  // does not re-define it), so init.d overrides it onto reload_service. Verified
  // on the dev stand pre-fix: one press on a conflicting UCI killed the daemon
  // and removed our nft table, and still returned rc 0.
  it("restart: same conflict, same refusal — does not tear anything down", async () => {
    const r = await reload(3, 3, "restart");
    expect(r.lifecycle).toBe("");
    expect(r.rc).not.toBe(0);
    expect(r.logger).toContain("refusing to reload");
  });

  it("restart: no conflict — still a real stop + start", async () => {
    const r = await reload(0, 0, "restart");
    expect(r.lifecycle).toBe("stop\nstart\n");
    expect(r.rc).toBe(0);
  });
});
