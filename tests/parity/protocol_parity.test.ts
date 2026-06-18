import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { canon } from "../helpers/canon.ts";
import { useGuest } from "../helpers/guest.ts";
import { runUcodeJSON } from "../helpers/ucode.ts";

// Port of tests/backend/test_protocol_parity.sh
// One ucode round-trip builds every corpus fixture into a {name: built} map;
// the host canon-compares each against its golden JSON file.

// The driver requires "corpus" from tests/parity (extra lib dir) and runs
// outbound/inbound builder for every fixture, returning a flat map.
const DRIVER = `
  let corpus = require("corpus");
  let ob = require("outbound");
  let inb = require("inbound");
  let res = {};
  for (let fx in corpus) {
    res[fx.name] = (fx.kind === "outbound")
      ? ob.build_constructor_for(fx.section, fx.type)
      : inb.build_one(fx.section);
  }
  print(sprintf("%J", res));
`;

describe("protocol parity", () => {
  useGuest();

  it("every corpus fixture deep-equals its golden", async () => {
    // corpus.uc lives in tests/parity, so pass it as extraLibDirs.
    // Shell equivalent: ucode -L tests/parity -L "$LIB" -e '...'
    const built = await runUcodeJSON<Record<string, unknown>>(
      DRIVER,
      [],
      ["tests/parity"],
    );

    const drift: string[] = [];
    for (const [name, got] of Object.entries(built)) {
      const goldenPath = `tests/parity/golden/${name}.json`;
      let want: unknown;
      try {
        want = JSON.parse(readFileSync(goldenPath, "utf8"));
      } catch {
        drift.push(`MISSING golden ${name}`);
        continue;
      }
      const a = JSON.stringify(canon(got));
      const b = JSON.stringify(canon(want));
      if (a !== b) {
        drift.push(`DRIFT ${name}\n  got=${a}\n  want=${b}`);
      }
    }

    expect(drift).toEqual([]);
  });
});
