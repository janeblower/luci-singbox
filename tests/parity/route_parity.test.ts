import { describe, expect, it } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { canon } from "../helpers/canon.ts";
import { useGuest } from "../helpers/guest.ts";
import { runUcodeJSON } from "../helpers/ucode.ts";

// Port of tests/backend/test_route_parity.sh
// Builds every route_corpus fixture via write_uci + uci.cursor +
// route.build_route_rules / ruleset.build_rule_sets.
// A fixture with no golden is a HARD FAILURE (not a skip).

// The DRIVER returns {name: built} for all fixtures.
// For kind="rule" it returns rules[0]; for kind="ruleset" it returns the
// matching entry from build_rule_sets by fx.tag.
// null is stored when nothing is produced (becomes a drift/fail in TS).
const DRIVER = `
  let uci_mod = require("uci");
  let fs      = require("fs");
  let corpus  = require("route_corpus");
  let route   = require("route");
  let ruleset = require("ruleset");
  let dns     = require("dns");

  function write_uci(sections, dir) {
    fs.mkdir(dir);
    let lines = [];
    for (let sec in sections) {
      push(lines, sprintf("config %s '%s'", sec.type, sec.name));
      for (let k in keys(sec.opts))
        push(lines, sprintf("\\toption %s '%s'", k, sec.opts[k]));
      for (let k in keys(sec.lists))
        for (let v in sec.lists[k])
          push(lines, sprintf("\\tlist %s '%s'", k, v));
    }
    let f = fs.open(sprintf("%s/singbox-ui", dir), "w");
    f.write(join("\\n", lines) + "\\n");
    f.close();
  }

  let res = {};

  for (let fx in corpus) {
    let dir = sprintf("/tmp/route_par_%s", fx.name);
    write_uci(fx.sections, dir);
    let cur = uci_mod.cursor(dir);
    let got = null;
    if (fx.kind == "rule") {
      let r = route.build_route_rules(cur, null);
      got = (length(r.rules) > 0) ? r.rules[0] : null;
    } else {
      let r = route.build_route_rules(cur, null);
      let referenced = r.referenced;
      let seen = {};
      for (let n in referenced) seen[n] = true;
      for (let n in dns.referenced_rulesets(cur)) {
        if (!seen[n]) { push(referenced, n); seen[n] = true; }
      }
      let sets = ruleset.build_rule_sets(cur, referenced);
      for (let e in sets) if (e.tag == fx.tag) got = e;
    }
    res[fx.name] = got;
  }

  print(sprintf("%J", res));
`;

describe("route parity", () => {
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
      // Missing golden = hard FAILURE (mirrors shell driver comment).
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
        drift.push(`MISSING output for ${name}`);
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
