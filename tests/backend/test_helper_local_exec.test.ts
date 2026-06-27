import { describe, expect, it } from "bun:test";
import { exec, putFile, warmConnection } from "../helpers/ssh.ts";

// Guards the ssh.ts in-guest local-exec mode. Active only when bun runs inside
// the OpenWrt guest (SINGBOX_TESTS_IN_VM=1, set by the VM-lane entrypoint), or
// when a developer exports the marker on the host. Skipped otherwise so the
// host ui/cross lanes never touch it.
const IN_GUEST = process.env.SINGBOX_TESTS_IN_VM === "1";

describe.if(IN_GUEST)("ssh helper local-exec mode (in-guest)", () => {
  it("warmConnection resolves without a live SSH master", async () => {
    await warmConnection(); // must not throw in local mode
    expect(true).toBe(true);
  });

  it("exec runs the command locally and returns stdout + zero exit", async () => {
    const r = await exec("echo hello-local");
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("hello-local");
  });

  it("exec propagates a non-zero exit code", async () => {
    const r = await exec("exit 7");
    expect(r.exitCode).toBe(7);
  });

  it("putFile writes locally and exec reads it back", async () => {
    await putFile("payload-local-123", "/tmp/sb-localmode-test.txt");
    const r = await exec("cat /tmp/sb-localmode-test.txt");
    expect(r.stdout.trim()).toBe("payload-local-123");
  });
});
