import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { closeConnection, exec, putFile, warmConnection } from "./ssh.ts";

describe("ssh helper (guest)", () => {
  beforeAll(() => warmConnection());
  afterAll(() => closeConnection());

  it("exec returns stdout + zero exit", async () => {
    const r = await exec("echo hello");
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("hello");
  });

  it("exec propagates non-zero exit", async () => {
    const r = await exec("exit 7");
    expect(r.exitCode).toBe(7);
  });

  it("putFile round-trips content (no scp)", async () => {
    await putFile("payload-123", "/tmp/sb-ssh-test.txt");
    const r = await exec("cat /tmp/sb-ssh-test.txt");
    expect(r.stdout.trim()).toBe("payload-123");
  });
});
