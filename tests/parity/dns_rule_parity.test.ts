import { describe, expect, it } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { useGuest } from "../helpers/guest.ts";
import { buildParity, goldenDrift } from "../helpers/parity.ts";

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
    const built = await buildParity(DRIVER, ["tests/parity"]);

    expect(goldenDrift(built)).toEqual([]);
  });
});
