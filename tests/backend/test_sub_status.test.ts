import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

// sub_status aggregates per-subscription { name, enabled, last_update, node_count }
// from UCI + the fetched sub_<name>.txt files. No network. We drive subscription.uc
// directly as a CLI subcommand (sub-status) with a fixture UCI dir + tmp dir.
// Mirrors tests/test_sub_status.sh.

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB =
  process.env.SB_VM_LIB ??
  "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";
const SUB = `${WORK}/singbox-ui/root/usr/share/singbox-ui/subscription.uc`;

const UCI_DIR = `/tmp/sub_status_${process.pid}/uci`;
const RUN_DIR = `/tmp/sub_status_${process.pid}/run`;

const UCI_CONFIG = `config outbound 'mysub'
\toption type 'subscription'
\toption enabled '1'
\toption sub_url 'https://example/sub'

config outbound 'offsub'
\toption type 'subscription'
\toption enabled '0'
\toption sub_url 'https://example/off'
`;

describe("test_sub_status", () => {
  useGuest();

  let entries: Array<Record<string, unknown>> = [];

  beforeAll(async () => {
    // Set up fixture dirs and files in guest
    await exec(`mkdir -p ${UCI_DIR} ${RUN_DIR}`);
    await putFile(UCI_CONFIG, `${UCI_DIR}/singbox-ui`);
    // mysub has 2 fetched nodes; offsub has no .txt (never fetched)
    await putFile("vless://a\nvmess://b\n", `${RUN_DIR}/sub_mysub.txt`);

    // Run sub-status
    const r = await exec(
      `env UCI_CONFIG_DIR=${UCI_DIR} SINGBOX_TMPDIR=${RUN_DIR} ucode -L ${LIB} ${SUB} sub-status 2>/dev/null`,
    );
    if (r.exitCode !== 0) {
      throw new Error(
        `sub-status exited ${r.exitCode}: ${r.stderr}\n${r.stdout}`,
      );
    }
    entries = JSON.parse(r.stdout) as Array<Record<string, unknown>>;
  });

  afterAll(async () => {
    await exec(`rm -rf /tmp/sub_status_${process.pid}`);
  });

  function findEntry(name: string): Record<string, unknown> | undefined {
    return entries.find((e) => e.name === name);
  }

  it("mysub: node_count is 2", () => {
    const e = findEntry("mysub");
    expect(e).toBeDefined();
    expect(e!.node_count).toBe(2);
  });

  it("mysub: enabled is '1'", () => {
    const e = findEntry("mysub");
    expect(e).toBeDefined();
    // ucode reads UCI string "1" and emits it as string "1" (uci_get_or_empty returns string)
    expect(String(e!.enabled)).toBe("1");
  });

  it("mysub: last_update is present (not null)", () => {
    const e = findEntry("mysub");
    expect(e).toBeDefined();
    expect(e!.last_update).not.toBeNull();
    expect(e!.last_update).not.toBeUndefined();
  });

  it("offsub: node_count is 0 (never fetched)", () => {
    const e = findEntry("offsub");
    expect(e).toBeDefined();
    expect(e!.node_count).toBe(0);
  });

  it("offsub: enabled is '0'", () => {
    const e = findEntry("offsub");
    expect(e).toBeDefined();
    expect(String(e!.enabled)).toBe("0");
  });
});
