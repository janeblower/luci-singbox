import { describe, expect, it } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { canon } from "../helpers/canon.ts";
import { useGuest } from "../helpers/guest.ts";
import { runUcodeJSON } from "../helpers/ucode.ts";

// Port of tests/backend/test_settings_parity.sh
// Builds every settings_corpus fixture via reg.get(kind, type) +
// filler.build(d, section), returns {name: built} map.
// A fixture with no golden is SKIPPED (not a failure).

const DRIVER = `
  let corpus = require("settings_corpus");
  let reg    = require("builder.settings.registry");
  let filler = require("builder._filler");
  let res = {};

  for (let fx in corpus) {
    let d = reg.get(fx.kind, fx.type);
    res[fx.name] = (d != null) ? filler.build(d, fx.section) : null;
  }

  print(sprintf("%J", res));
`;

describe("settings parity", () => {
  useGuest();

  it("every corpus fixture with a golden deep-equals it", async () => {
    const built = await runUcodeJSON<Record<string, unknown>>(
      DRIVER,
      [],
      ["tests/parity"],
    );

    const drift: string[] = [];
    for (const [name, got] of Object.entries(built)) {
      const goldenPath = `tests/parity/golden/${name}.json`;
      // No golden yet — skip (mirrors shell SKIP behaviour).
      if (!existsSync(goldenPath)) continue;

      let want: unknown;
      try {
        want = JSON.parse(readFileSync(goldenPath, "utf8"));
      } catch {
        drift.push(`UNREADABLE golden ${name}`);
        continue;
      }

      if (got === null || got === undefined) {
        drift.push(`NULL output for ${name}`);
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
