import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec } from "../helpers/ssh.ts";

// Golden regression for the pure-ucode bbolt reader (lib/bbolt.uc), which
// replaced the former per-arch Rust bbolt-client. bbolt-client/test.sh drives the
// reader against frozen Go golden hashes (cache/stress trees + -r unwrap) and 6
// adversarial forged-db cases (cyclic/pgid-wrap/forged count·pos·ksize/
// tiny-pageSize+huge-pgid) that must clean-exit, never OOB-abort.
//
// The reader is a MODULE: production (nft-rulesets.uc) requires it in-process and
// forks nothing. A shell harness still needs a process to run, so test.sh drives
// it through bbolt-client/bbolt-cli.uc — a test-only CLI driver, formerly the
// packaged usr/libexec/singbox-ui/bbolt-client shim. Same reader, same golden
// hashes; the driver just turns the reader's exceptions back into exit(1).
//
// Runs in the backend VM lane because that is the only place real OpenWrt
// ucode + ucode-mod-fs are guaranteed present and match production exactly; the
// old cross-lane test skipped in CI unless a native binary happened to exist.
const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB =
  process.env.SB_VM_LIB ?? `${WORK}/singbox-ui/root/usr/share/singbox-ui/lib`;
const CLI = `${WORK}/bbolt-client/bbolt-cli.uc`;
const TEST_SH = `${WORK}/bbolt-client/test.sh`;

describe("bbolt golden suite (pure-ucode reader)", () => {
  useGuest();

  // Slow by construction: the harness re-spawns the driver per bucket AND per key
  // (three ucode processes per key), and the guest is an emulated CPU — far past
  // bun's 5s default. The work is process spawns, not compute, so this stays a
  // couple of minutes rather than blowing up.
  it("test.sh passes against the ucode reader (golden + adversarial)", async () => {
    const r = await exec(`RUN="ucode -L${LIB} ${CLI}" sh ${TEST_SH}`);
    expect(r.exitCode, `${r.stdout}\n${r.stderr}`).toBe(0);
  }, 300_000);
});
