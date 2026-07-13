import { readFileSync } from "node:fs";
import { isDeepStrictEqual } from "node:util";
import { runUcodeJSON } from "./ucode.ts";

// Every parity suite builds its corpus through THIS wrapper, with the core version
// pinned above every min_version gate in the tree.
//
// Why: _filler gates emission on min_version (an unknown key is not ignored —
// sing-box refuses the whole config), so an unpinned build emits whatever the
// guest's `apk add sing-box` happened to install. The goldens would then be a
// function of ambient environment state: the guest ships 1.12 today, and the day
// it resolves 1.13 the same fixture grows three keys and parity goes red with zero
// code change. Parity asserts WHAT A DESCRIPTOR EMITS, with every field present;
// version gating is a separate concern with its own dedicated tests
// (tests/backend/test_listen_shared_version_gate.test.ts pins each boundary
// explicitly). Pin high, and no golden is ever silently reshaped by the guest.
const PARITY_ENV = { SINGBOX_CORE_VERSION: "99.0" };

export function buildParity<T = Record<string, unknown>>(
  driver: string,
  extraLibDirs: string[] = [],
): Promise<T> {
  return runUcodeJSON<T>(driver, [], extraLibDirs, PARITY_ENV);
}

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
