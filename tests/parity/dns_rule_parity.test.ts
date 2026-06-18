import { describe, expect, it } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { canon } from "../helpers/canon.ts";
import { useGuest } from "../helpers/guest.ts";
import { runUcodeJSON } from "../helpers/ucode.ts";

// Port of tests/backend/test_dns_rule_parity.sh
// Builds every dns_rule_corpus fixture via reg.get("dns_rule", type) +
// filler.build(d, section), returns {name: built} map.
// A fixture with no golden is a HARD FAILURE (not a skip).

const DRIVER = `
  let corpus = require("dns_rule_corpus");
  let reg    = require("builder.dns_rule.registry");
  let filler = require("builder._filler");
  let res = {};

  for (let fx in corpus) {
    let d = reg.get("dns_rule", fx.type);
    res[fx.name] = (d != null) ? filler.build(d, fx.section) : null;
  }

  print(sprintf("%J", res));
`;

describe("dns rule parity", () => {
  useGuest();

  it("every corpus fixture deep-equals its golden", async () => {
    const built = await runUcodeJSON<Record<string, unknown>>(
      DRIVER,
      [],
      ["tests/parity"],
    );

    const drift: string[] = [];
    for (const [name, got] of Object.entries(built)) {
      const goldenPath = `tests/parity/golden/${name}.json`;
      // Missing golden = hard FAILURE (mirrors shell driver behaviour).
      if (!existsSync(goldenPath)) {
        drift.push(`MISSING golden ${name}`);
        continue;
      }

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
