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
    expect(g.rc).not.toBe(0);
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

// init.d must honour the generator's exit code. Without it procd starts the
// daemon on the STALE /tmp/singbox-ui.json and "we refuse to start" is a lie:
// the operator's edit is silently discarded and we report success.
// STATEFUL (touches /tmp/singbox-ui.json) — bun runs test files serially.
describe("init.d refuses to start on a generator refusal", () => {
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
      // generate.uc refuses (rc 1) and, like the real one, leaves the previous
      // config in place; everything else succeeds.
      [
        "ucode",
        `#!/bin/sh
for _arg in "$@"; do
  case "$_arg" in
    */generate.uc) echo "generate: refusing to build" 1>&2; exit 1 ;;
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
    expect(r.exitCode).not.toBe(0);

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
