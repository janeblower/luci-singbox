import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

// call_refresh forwards a valid `name` as the 3rd CLI arg to subscription.uc
// and rejects an invalid name (falls back to a global refresh, no name forwarded).
// Mirrors tests/test_refresh_name.sh.

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB =
  process.env.SB_VM_LIB ?? "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";
const HANDLER = `${WORK}/singbox-ui/root/usr/libexec/rpcd/singbox-ui`;

const STUB_DIR = `/tmp/refresh_name_${process.pid}`;
const SUB_STUB = `${STUB_DIR}/sub_stub.uc`;
const ARGV_OUT = `${STUB_DIR}/argv`;

// Stub subscription.uc: records ARGV (joined by newlines) to $ARGV_OUT and exits 0.
const SUB_STUB_SRC = `let fs=require("fs");
let f=fs.open(getenv("ARGV_OUT"),"w");
if (f) { f.write(join("\\n", ARGV)); f.close(); }
`;

describe("test_refresh_name", () => {
  useGuest();

  beforeAll(async () => {
    await exec(`mkdir -p ${STUB_DIR}`);
    await putFile(SUB_STUB_SRC, SUB_STUB);
  });

  afterAll(async () => {
    await exec(`rm -rf ${STUB_DIR}`);
  });

  // Call the rpcd handler's refresh method, piping JSON args on stdin.
  // Returns the content of the ARGV_OUT file (lines the stub received).
  async function callRefresh(jsonArgs: string): Promise<string> {
    // We also need to stub RULESETS_UC to prevent it running the real nft-rulesets.uc.
    // A trivial /bin/true stub suffices — it exits 0 and records nothing.
    const r = await exec(
      `printf '%s' ${JSON.stringify(jsonArgs)} | env SUBSCRIPTION_UC=${SUB_STUB} RULESETS_UC=/bin/true ARGV_OUT=${ARGV_OUT} ucode -L ${LIB} ${HANDLER} call refresh >/dev/null 2>&1; cat ${ARGV_OUT} 2>/dev/null || true`,
    );
    return r.stdout;
  }

  it("valid name is forwarded as a CLI arg along with 'force'", async () => {
    const got = await callRefresh('{"what":"subscriptions","name":"mysub"}');
    const lines = got.split("\n").filter((l) => l.length > 0);
    expect(lines).toContain("mysub");
    expect(lines).toContain("force");
  });

  it("invalid name with shell metacharacter is NOT forwarded", async () => {
    const got = await callRefresh('{"what":"subscriptions","name":"a;b rm"}');
    expect(got).not.toContain(";");
  });
});
