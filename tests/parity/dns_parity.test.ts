import { describe, expect, it } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { canon } from "../helpers/canon.ts";
import { useGuest } from "../helpers/guest.ts";
import { runUcodeJSON } from "../helpers/ucode.ts";

// Port of tests/backend/test_dns_parity.sh
// Builds every dns_corpus fixture via write_uci_config + uci.cursor +
// dns.build_dns, returns {name: servers[0]} map.
// A fixture with no golden is SKIPPED (not a failure).

const DRIVER = `
  let uci_mod = require("uci");
  let fs      = require("fs");
  let corpus  = require("dns_corpus");

  function write_uci_config(section) {
    let name    = section[".name"];
    let tmp_dir = sprintf("/tmp/dns_par_%s", name);
    fs.mkdir(tmp_dir);
    let lines = [ sprintf("config dns_server '%s'", name) ];
    for (let k in keys(section)) {
      if (k === ".name") continue;
      let v = section[k];
      if (type(v) === "array") {
        for (let item in v)
          push(lines, sprintf("\\tlist %s '%s'", k, item));
      } else {
        push(lines, sprintf("\\toption %s '%s'", k, v));
      }
    }
    let f = fs.open(sprintf("%s/singbox-ui", tmp_dir), "w");
    f.write(join("\\n", lines) + "\\n");
    f.close();
    return tmp_dir;
  }

  let dns = require("dns");
  let res = {};

  for (let fx in corpus) {
    let tmp_dir = write_uci_config(fx.section);
    let cur     = uci_mod.cursor(tmp_dir);
    let out     = dns.build_dns(cur);
    let srv = (out != null && type(out.servers) === "array" && length(out.servers) > 0)
              ? out.servers[0] : null;
    res[fx.name] = srv;
  }

  print(sprintf("%J", res));
`;

describe("dns parity", () => {
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
      // No golden yet — skip until one is added (mirrors shell SKIP behaviour).
      if (!existsSync(goldenPath)) continue;

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
