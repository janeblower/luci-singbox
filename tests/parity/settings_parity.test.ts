import { describe, expect, it } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { useGuest } from "../helpers/guest.ts";
import { goldenDrift } from "../helpers/parity.ts";
import { runUcodeJSON } from "../helpers/ucode.ts";

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

    expect(goldenDrift(built)).toEqual([]);
  });
});
