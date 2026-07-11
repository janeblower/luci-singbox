import { readFileSync } from "node:fs";
import { isDeepStrictEqual } from "node:util";

// Shared golden-comparison for the five parity suites (protocol / dns / dns_rule
// / route / settings), which each carried a byte-identical copy of this loop.
//
// isDeepStrictEqual replaces the old helpers/canon.ts + JSON.stringify(canon(x))
// dance: it is already key-order-agnostic and array-order-significant, which is
// exactly the parity contract (key order in the emitted JSON is not load-bearing;
// array order is). The ucode-side `canon` module is a different thing and stays.
//
// Returns the drift lines; the caller asserts they are empty so the failure
// message names every drifting fixture at once.
export function goldenDrift(
  built: Record<string, unknown>,
  goldenDir = "tests/parity/golden",
): string[] {
  const drift: string[] = [];

  for (const [name, got] of Object.entries(built)) {
    let want: unknown;
    try {
      want = JSON.parse(readFileSync(`${goldenDir}/${name}.json`, "utf8"));
    } catch {
      drift.push(`MISSING golden ${name}`);
      continue;
    }
    if (!isDeepStrictEqual(got, want)) {
      drift.push(
        `DRIFT ${name}\n  got=${JSON.stringify(got)}\n  want=${JSON.stringify(want)}`,
      );
    }
  }

  return drift;
}
