import { describe, expect, it } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

// Port of tests/backend/test_protocol_emit.sh
// Walks tests/fixtures/protocols/*.uci, runs generate.uc against each, then
// evaluates the paired .expect expression against the resulting JSON (bound as `c`).

const FIXTURES_DIR = "tests/fixtures/protocols";
const GENERATE_UC = "singbox-ui/root/usr/share/singbox-ui/generate.uc";
const LIB =
  process.env.SB_VM_LIB ?? "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";
const WORK = process.env.SB_VM_WORK ?? "/tmp/work";

describe("protocol emit (fixture-driven generate.uc)", () => {
  useGuest();

  // Discover fixture pairs on the host
  let fixtures: Array<{ name: string; uci: string; expr: string }> = [];
  try {
    const files = readdirSync(FIXTURES_DIR).filter((f) => f.endsWith(".uci"));
    for (const f of files) {
      const name = f.replace(".uci", "");
      const expectPath = `${FIXTURES_DIR}/${name}.expect`;
      let expr: string;
      try {
        expr = readFileSync(expectPath, "utf8").trim();
      } catch {
        // No .expect file — skip per shell test logic (NOEXPECT)
        continue;
      }
      const uci = readFileSync(`${FIXTURES_DIR}/${f}`, "utf8");
      fixtures.push({ name, uci, expr });
    }
  } catch {
    // fixtures dir absent — pass immediately (mirrors shell: "PASS: no fixtures yet")
    fixtures = [];
  }

  if (fixtures.length === 0) {
    it("no fixtures present — pass", () => {
      expect(true).toBe(true);
    });
  }

  for (const { name, uci, expr } of fixtures) {
    it(`fixture: ${name}`, async () => {
      // Stage UCI config into guest
      const uciRemote = `/tmp/sb-emit-${process.pid}-${name}/singbox-ui`;
      const outFile = `/tmp/sb-emit-${process.pid}-${name}-out.json`;
      const subsDir = `/tmp/sb-emit-${process.pid}-${name}-subs`;

      // Create dirs, write UCI
      await exec(`mkdir -p $(dirname ${uciRemote}) ${subsDir}`);
      const put = await putFile(uci, uciRemote);
      expect(put.exitCode).toBe(0);

      // Run generate.uc
      const genResult = await exec(
        `cd ${WORK} && UCI_CONFIG_DIR=$(dirname ${uciRemote}) SINGBOX_TMPDIR=${subsDir} SINGBOX_CONFIG=${outFile} ` +
          `ucode -L ${LIB} ${GENERATE_UC} >/dev/null 2>&1; echo $?`,
      );
      const rc = genResult.stdout.trim();
      expect(rc).toBe("0");

      // Evaluate .expect expression against generated JSON (c = parsed config)
      const evalResult = await exec(
        `cd ${WORK} && ucode -L ${LIB} -e "
          let fs = require('fs');
          let c = json(fs.readfile('${outFile}'));
          print((${expr}) ? 'OK' : 'BAD');
        " 2>&1`,
      );
      expect(evalResult.stdout.trim()).toBe("OK");

      // Cleanup
      await exec(
        `rm -f ${uciRemote} ${outFile}; rm -rf $(dirname ${uciRemote}) ${subsDir}`,
      );
    });
  }
});
