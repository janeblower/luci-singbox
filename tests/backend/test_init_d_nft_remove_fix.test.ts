import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

// Regression test for svc-1: init.d blackhole fix + #2/#3.
// __do_start no longer branches on `nftables.uc needed`. It calls
// `nftables.uc apply` UNCONDITIONALLY: cmd_apply already drops the core table
// when no tproxy/tun inbound needs it AND still applies plugin nft fragments —
// which the old `needed=0 -> remove` branch skipped (a plugin's table was then
// absent after boot until the first cron apply). So init.d calls `apply` and
// never `remove` (nor `needed`); apply's atomic add+delete+table self-replaces,
// keeping the no-pre-remove blackhole guarantee.

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const INIT = `${WORK}/singbox-ui/root/etc/init.d/singbox-ui`;

let TD = ""; // TMPDIR on the guest

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

describe("test_init_d_nft_remove_fix", () => {
  useGuest();

  beforeAll(async () => {
    const r = await exec("mktemp -d");
    TD = r.stdout.trim();

    await exec(`mkdir -p '${TD}/bin'`);

    // logger stub
    await putFile(
      `#!/bin/sh
echo "logger $*" >>"${TD}/logger.log"
`,
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
        `#!/bin/sh
echo "${fn} $*" >>"${TD}/procd.log"
`,
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

  // The ucode stub answers `apply` (exit 0) and, if ever probed, `needed` — so
  // the test can assert __do_start no longer probes `needed` nor calls `remove`.
  async function installNftUcode(): Promise<void> {
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
        apply)   exit 0 ;;
        remove)  exit 0 ;;
    esac
done
exit 0
`,
      `${TD}/bin/ucode`,
    );
    await exec(`chmod +x '${TD}/bin/ucode'`);
  }

  it("svc-1/#3: __do_start calls `nftables.uc apply` unconditionally", async () => {
    await installNftUcode();
    await clearLogs();

    const r = await exec(runInit("start_service"));
    expect(r.exitCode).toBe(0);

    const ucode = (await exec(`cat '${TD}/ucode.log'`)).stdout;
    expect(ucode).toContain("nftables.uc apply");
  });

  it("svc-1/#3: __do_start never calls `remove` nor probes `needed`", async () => {
    await installNftUcode();
    await clearLogs();

    const r = await exec(runInit("start_service"));
    expect(r.exitCode).toBe(0);

    const ucode = (await exec(`cat '${TD}/ucode.log'`)).stdout;
    // The `needed`/`remove` branch is gone: cmd_apply drops the table itself when
    // not needed and applies plugin fragments either way. No unconditional
    // pre-remove ⇒ no blackhole window if apply fails.
    expect(ucode).not.toContain("nftables.uc remove");
    expect(ucode).not.toContain("nftables.uc needed");
  });
});
