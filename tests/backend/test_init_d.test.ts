import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

// Port of tests/backend/test_init_d.sh
// Drives /etc/init.d/singbox-ui start_service/stop_service via stubbed
// ucode/uci/logger/procd helpers and verifies lifecycle, fetch, locks.
// STATEFUL — must run serially (not concurrent).

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const INIT = `${WORK}/singbox-ui/root/etc/init.d/singbox-ui`;

let TD = ""; // TMPDIR on the guest

// Run a shell command inside the init.d context (sources it first).
// Passes PATH and SINGBOX_BIN so stubs shadow real binaries.
function runInit(cmd: string): string {
  return `PATH="${TD}/bin:$PATH" SINGBOX_BIN="${TD}/bin/sing-box" sh -c "
    . '${INIT}'
    ${cmd}
  "`;
}

async function clearLogs(): Promise<void> {
  await exec(`
    : >"${TD}/ucode.log"
    : >"${TD}/logger.log"
    : >"${TD}/procd.log"
    : >"${TD}/singbox.log"
    rm -f /tmp/singbox-ui.json
  `);
}

// Install the happy-path ucode stub (creates config on generate.uc)
async function installHappyUcode(): Promise<void> {
  await putFile(
    `#!/bin/sh
echo "ucode $*" >>"${TD}/ucode.log"
echo "SINGBOX_BOOT_FETCH=$SINGBOX_BOOT_FETCH" >>"${TD}/ucode.log"
for _arg in "$@"; do
    case "$_arg" in
        */generate.uc)   echo '{"ok":true}' > /tmp/singbox-ui.json; break ;;
    esac
done
exit 0
`,
    `${TD}/bin/ucode`,
  );
  await exec(`chmod +x '${TD}/bin/ucode'`);
}

async function installHappySingbox(): Promise<void> {
  await putFile(
    `#!/bin/sh
echo "sing-box $*" >>"${TD}/singbox.log"
exit 0
`,
    `${TD}/bin/sing-box`,
  );
  await exec(`chmod +x '${TD}/bin/sing-box'`);
}

describe("test_init_d", () => {
  useGuest();

  beforeAll(async () => {
    const r = await exec("mktemp -d");
    TD = r.stdout.trim();

    await exec(`mkdir -p '${TD}/bin'`);

    // uci stub: exit 1 so tproxy.enabled check skips nft apply
    await putFile("#!/bin/sh\nexit 1\n", `${TD}/bin/uci`);
    await exec(`chmod +x '${TD}/bin/uci'`);

    // logger stub
    await putFile(
      `#!/bin/sh\necho "logger $*" >>"${TD}/logger.log"\n`,
      `${TD}/bin/logger`,
    );
    await exec(`chmod +x '${TD}/bin/logger'`);

    // procd stubs
    for (const fn of [
      "procd_open_instance",
      "procd_set_param",
      "procd_close_instance",
    ]) {
      await putFile(
        `#!/bin/sh\necho "${fn} $*" >>"${TD}/procd.log"\n`,
        `${TD}/bin/${fn}`,
      );
      await exec(`chmod +x '${TD}/bin/${fn}'`);
    }

    await installHappyUcode();
    await installHappySingbox();

    await exec(
      `touch '${TD}/ucode.log' '${TD}/logger.log' '${TD}/procd.log' '${TD}/singbox.log'`,
    );
  });

  afterAll(async () => {
    if (TD) {
      await exec(
        `rm -rf '${TD}'; rm -rf /tmp/singbox-ui/.lifecycle.lock; rm -f /tmp/singbox-ui.json`,
      );
    }
  });

  it("happy path: subs + rulesets fetched, SINGBOX_BOOT_FETCH=1, procd opened", async () => {
    await clearLogs();
    const r = await exec(runInit("start_service"));
    expect(r.exitCode).toBe(0);

    const ucode = (await exec(`cat '${TD}/ucode.log'`)).stdout;
    const procd = (await exec(`cat '${TD}/procd.log'`)).stdout;
    expect(ucode).toContain("fetch-subs");
    expect(ucode).toContain("nft-rulesets");
    expect(ucode).toContain("SINGBOX_BOOT_FETCH=1");
    expect(procd).toContain("procd_open_instance");
  });

  it("nft apply gated by 'needed' (stub returns empty → skip)", async () => {
    await clearLogs();
    const r = await exec(runInit("start_service"));
    expect(r.exitCode).toBe(0);
    const ucode = (await exec(`cat '${TD}/ucode.log'`)).stdout;
    expect(ucode).not.toContain("nftables.uc apply");
  });

  it("C2.1.12: defensive nftables.uc remove called before apply decision", async () => {
    await clearLogs();
    const r = await exec(runInit("start_service"));
    expect(r.exitCode).toBe(0);
    const ucode = (await exec(`cat '${TD}/ucode.log'`)).stdout;
    expect(ucode).toContain("nftables.uc remove");
  });

  it("G4: nft apply failure is logged via logger", async () => {
    await putFile(
      `#!/bin/sh
echo "ucode $*" >>"${TD}/ucode.log"
for _arg in "$@"; do
    case "$_arg" in
        */generate.uc)   echo '{"ok":true}' > /tmp/singbox-ui.json; exit 0 ;;
    esac
done
for _arg in "$@"; do
    case "$_arg" in
        needed)  echo 1; exit 0 ;;
        apply)   exit 1 ;;
    esac
done
exit 0
`,
      `${TD}/bin/ucode`,
    );
    await exec(`chmod +x '${TD}/bin/ucode'`);
    await clearLogs();
    await exec(`${runInit("start_service")} || true`);

    const logger = (await exec(`cat '${TD}/logger.log'`)).stdout;
    expect(logger).toContain("nft apply failed");
  });

  it("G4: nft apply rc=0 does NOT log failure", async () => {
    await putFile(
      `#!/bin/sh
echo "ucode $*" >>"${TD}/ucode.log"
for _arg in "$@"; do
    case "$_arg" in
        */generate.uc)   echo '{"ok":true}' > /tmp/singbox-ui.json; exit 0 ;;
    esac
done
for _arg in "$@"; do
    case "$_arg" in
        needed)  echo 1; exit 0 ;;
    esac
done
exit 0
`,
      `${TD}/bin/ucode`,
    );
    await exec(`chmod +x '${TD}/bin/ucode'`);
    await clearLogs();
    await exec(runInit("start_service"));

    const logger = (await exec(`cat '${TD}/logger.log'`)).stdout;
    expect(logger).not.toContain("nft apply failed");

    await installHappyUcode();
  });

  it("G7: stop_service silences stderr from nftables.uc remove", async () => {
    await putFile(
      `#!/bin/sh
echo "noisy ucode stderr" 1>&2
echo "ucode $*" >>"${TD}/ucode.log"
exit 0
`,
      `${TD}/bin/ucode`,
    );
    await exec(`chmod +x '${TD}/bin/ucode'`);
    await clearLogs();

    // Redirect stdout to /dev/null and capture stderr
    const r = await exec(`${runInit("stop_service")} 2>&1 >/dev/null || true`);
    expect(r.stdout).not.toContain("noisy ucode stderr");

    const ucode = (await exec(`cat '${TD}/ucode.log'`)).stdout;
    expect(ucode).toContain("nftables.uc remove");

    await installHappyUcode();
  });

  it("fail-fast: start_service returns non-zero when config not generated", async () => {
    // ucode stub: does NOT create the config
    await putFile(
      `#!/bin/sh\necho "ucode $*" >>"${TD}/ucode.log"\nexit 0\n`,
      `${TD}/bin/ucode`,
    );
    await exec(`chmod +x '${TD}/bin/ucode'`);
    await clearLogs();

    const r = await exec(
      `${runInit("start_service")} 2>/dev/null; echo "RC=$?"`,
    );
    const rc = parseInt((r.stdout.match(/RC=(\d+)/) ?? ["", "0"])[1], 10);
    expect(rc).toBeGreaterThan(0);

    const logger = (await exec(`cat '${TD}/logger.log'`)).stdout;
    expect(logger).toContain("refusing to start");

    const procd = (await exec(`cat '${TD}/procd.log'`)).stdout;
    expect(procd).not.toContain("procd_open_instance");

    await installHappyUcode();
  });

  it("S6.1: sing-box check rejection → refuse to start, no procd", async () => {
    // ucode creates config; sing-box fails `check`
    await putFile(
      `#!/bin/sh
echo "ucode $*" >>"${TD}/ucode.log"
for _arg in "$@"; do
    case "$_arg" in
        */generate.uc)   echo '{"ok":true}' > /tmp/singbox-ui.json; exit 0 ;;
    esac
done
exit 0
`,
      `${TD}/bin/ucode`,
    );
    await exec(`chmod +x '${TD}/bin/ucode'`);

    await putFile(
      `#!/bin/sh
echo "sing-box $*" >>"${TD}/singbox.log"
[ "$1" = "check" ] && { echo "decode config: unknown field" >&2; exit 1; }
exit 0
`,
      `${TD}/bin/sing-box`,
    );
    await exec(`chmod +x '${TD}/bin/sing-box'`);
    await clearLogs();

    const r = await exec(
      `${runInit("start_service")} 2>/dev/null; echo "RC=$?"`,
    );
    const rc = parseInt((r.stdout.match(/RC=(\d+)/) ?? ["", "0"])[1], 10);
    expect(rc).toBeGreaterThan(0);

    const singbox = (await exec(`cat '${TD}/singbox.log'`)).stdout;
    expect(singbox).toContain("check");

    const logger = (await exec(`cat '${TD}/logger.log'`)).stdout;
    expect(logger).toContain("rejected config");

    const procd = (await exec(`cat '${TD}/procd.log'`)).stdout;
    expect(procd).not.toContain("procd_open_instance");

    await installHappyUcode();
    await installHappySingbox();
  });

  it("missed-1(a): lifecycle lock is re-entrant (depth counter)", async () => {
    await exec("rm -rf /tmp/singbox-ui/.lifecycle.lock");

    const r = await exec(`
      PATH="${TD}/bin:$PATH" sh -c "
        . '${INIT}'
        _lc_acquire; _lc_acquire
        [ -d /tmp/singbox-ui/.lifecycle.lock ] || exit 3
        _lc_release
        [ -d /tmp/singbox-ui/.lifecycle.lock ] || exit 4
        _lc_release
        [ -d /tmp/singbox-ui/.lifecycle.lock ] && exit 5
        exit 0
      "
    `);
    expect(r.exitCode).toBe(0);
  });

  it("missed-1(b): start_service releases the lifecycle lock", async () => {
    await exec(
      "rm -rf /tmp/singbox-ui/.lifecycle.lock; rm -f /tmp/singbox-ui.json",
    );
    await clearLogs();

    const r = await exec(runInit("start_service"));
    expect(r.exitCode).toBe(0);

    const lockState = await exec(
      "[ -d /tmp/singbox-ui/.lifecycle.lock ] && echo LOCKED || echo FREE",
    );
    expect(lockState.stdout.trim()).toBe("FREE");
  });

  it("missed-1(c): stale lifecycle lock (past TTL=1s) is reclaimed without deadlock", async () => {
    await exec(
      "rm -f /tmp/singbox-ui.json; rm -rf /tmp/singbox-ui/.lifecycle.lock",
    );
    await clearLogs();

    // Create a stale lock with a fake pid, then age it past TTL=1s via
    // a guest-side sleep (avoids unreliable host-side setTimeout).
    const r = await exec(`
      mkdir -p /tmp/singbox-ui/.lifecycle.lock
      echo 999999 > /tmp/singbox-ui/.lifecycle.lock/pid
      sleep 2
      SINGBOX_LIFECYCLE_TTL=1 ${runInit("start_service")} 2>/dev/null
      echo "RC=$?"
      [ -d /tmp/singbox-ui/.lifecycle.lock ] && echo "LOCKED" || echo "FREE"
    `);
    expect(r.exitCode).toBe(0);

    const rc = parseInt((r.stdout.match(/RC=(\d+)/) ?? ["", "0"])[1], 10);
    expect(rc).toBe(0);

    expect(r.stdout).toContain("FREE");
  });
});
