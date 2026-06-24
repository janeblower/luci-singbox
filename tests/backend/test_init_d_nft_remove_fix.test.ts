import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

// Regression test for svc-1: init.d blackhole fix.
// Verifies that nftables.uc remove is only called when nft is NOT needed,
// and that apply's atomic add+delete+table self-replaces without a prior
// unconditional remove.

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

  it("svc-1: nftables.uc remove NOT called when nft is needed (no unconditional remove)", async () => {
    // uci stub that says nft is needed
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
    esac
done
exit 0
`,
      `${TD}/bin/ucode`,
    );
    await exec(`chmod +x '${TD}/bin/ucode'`);
    await clearLogs();

    const r = await exec(runInit("start_service"));
    expect(r.exitCode).toBe(0);

    const ucode = (await exec(`cat '${TD}/ucode.log'`)).stdout;
    // Remove should NOT appear before apply
    const removeLines = ucode.split("\n").filter((l) => l.includes("remove"));
    const applyLines = ucode.split("\n").filter((l) => l.includes("apply"));

    // If both exist, apply must come BEFORE remove (no unconditional pre-remove)
    if (removeLines.length > 0 && applyLines.length > 0) {
      const firstRemove = ucode.indexOf("remove");
      const firstApply = ucode.indexOf("apply");
      expect(firstApply).toBeLessThan(firstRemove);
    } else if (removeLines.length > 0) {
      // Only remove, no apply that's wrong for the "needed" case
      expect(applyLines.length).toBeGreaterThan(0);
    }
  });

  it("svc-1: nftables.uc remove IS called in else branch when nft not needed", async () => {
    // uci stub that says nft is NOT needed
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
        needed)  echo 0; exit 0 ;;
    esac
done
exit 0
`,
      `${TD}/bin/ucode`,
    );
    await exec(`chmod +x '${TD}/bin/ucode'`);
    await clearLogs();

    const r = await exec(runInit("start_service"));
    expect(r.exitCode).toBe(0);

    const ucode = (await exec(`cat '${TD}/ucode.log'`)).stdout;
    // Remove SHOULD be called when nft is not needed
    expect(ucode).toContain("nftables.uc remove");
    // But apply should NOT be called
    expect(ucode).not.toContain("nftables.uc apply");
  });
});
