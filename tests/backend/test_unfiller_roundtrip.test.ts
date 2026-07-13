import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcodeJSON } from "../helpers/ucode.ts";

// COVERAGE GUARD for the JSON editor's reverse mapping.
//
// builder/_unfiller.uc must be an exact inverse of builder/_filler.uc. The
// strongest proof available is the parity corpus, which exists precisely because
// it covers every emit feature combination: nested groups, gates, tagged-union
// transports, users lists, single_fallback credentials, merge blocks, every
// coerce variant, version-gated fields.
//
// For every fixture:
//   json1 = filler.build(d, section)
//   r     = unfiller.parse(d, json1)
//   json2 = filler.build(d, <section rebuilt from r>)
//   json1 == json2   (semantically — key order is not load-bearing here)
//
// The rebuilt section carries ONLY what lib/json_editor.js writes back: the
// section name, the discriminator, r.fields, and r.extra stashed in json_extra.
// So a field _unfiller fails to map cannot quietly vanish — it either breaks the
// round-trip or surfaces in `extra`, which the UI makes the user confirm.

// Key order is not load-bearing (the project's parity invariant is semantic), and
// json_extra merges last, so canonicalise before comparing.
const DRIVER = `
  let filler   = require("builder._filler");
  let unfiller = require("builder._unfiller");
  require("inbound");
  require("outbound");
  let reg    = require("builder.protocols.registry");
  let corpus = require("corpus");

  function canon(v) {
    if (type(v) === "array")  { let a = []; for (let x in v) push(a, canon(x)); return a; }
    if (type(v) === "object") { let o = {}; for (let k in sort(keys(v))) o[k] = canon(v[k]); return o; }
    return v;
  }

  let out = [];
  for (let fx in corpus) {
    let d = reg.get(fx.kind, fx.type);
    if (d == null) { push(out, { name: fx.name, skipped: "no descriptor" }); continue; }

    let j1 = filler.build(d, fx.section);
    if (j1 == null) { push(out, { name: fx.name, skipped: "build returned null" }); continue; }

    let r = unfiller.parse(d, j1);

    // Exactly what the JSON editor writes back — nothing else.
    let s2 = { ".name": fx.section[".name"] };
    s2[fx.kind === "inbound" ? "protocol" : "type"] = fx.type;
    for (let k in r.fields) s2[k] = r.fields[k];
    if (length(keys(r.extra))) s2.json_extra = sprintf("%J", r.extra);

    let j2 = filler.build(d, s2);

    push(out, {
      name:  fx.name,
      kind:  fx.kind,
      type:  fx.type,
      same:  sprintf("%J", canon(j1)) == sprintf("%J", canon(j2)),
      extra: keys(r.extra),
      j1:    sprintf("%J", j1),
      j2:    sprintf("%J", j2),
    });
  }
  print(sprintf("%J", out));
`;

interface Row {
  name: string;
  kind?: string;
  type?: string;
  same?: boolean;
  extra?: string[];
  j1?: string;
  j2?: string;
  skipped?: string;
}

// Fixtures that legitimately never reach the filler, so there is nothing to
// invert. Hardcoded so a NEW one can't slip in unnoticed:
//   cloudflared_in — has no listen_port on purpose (it tests that guard)
//   json_in_raw    — the raw-JSON escape hatch, not a descriptor build
//   awg_warp_basic — a plugin descriptor; its lib dir is not on this -L path
const EXPECTED_SKIPS = ["awg_warp_basic", "cloudflared_in", "json_in_raw"];

describe("_unfiller round-trips the whole parity corpus", () => {
  useGuest();

  let rows: Row[] = [];

  it("runs every fixture through build -> parse -> build", async () => {
    rows = (await runUcodeJSON(DRIVER, [], ["tests/parity"])) as Row[];
    expect(rows.length).toBeGreaterThan(70);
    expect(
      rows
        .filter((r) => r.skipped)
        .map((r) => r.name)
        .sort(),
    ).toEqual(EXPECTED_SKIPS);
  });

  it("is an exact inverse for every fixture", () => {
    const drifted = rows
      .filter((r) => !r.skipped && !r.same)
      .map(
        (r) => `${r.kind}/${r.type} ${r.name}\n  was: ${r.j1}\n  got: ${r.j2}`,
      );
    expect(drifted).toEqual([]);
  });

  it("leaves nothing unmapped except a discard-column users list", () => {
    // Anything else here means _unfiller grew a blind spot: a key the descriptor
    // DOES model but the inverse walk missed. It would still survive (json_extra
    // re-emits it verbatim), but the user would be asked to confirm a field the
    // form already owns — and worse, the form and the raw copy could then drift.
    //
    // shadowsocks is the sole exception: its users spec `discard`s the `method`
    // column, so the emitted JSON carries nothing to rebuild the UCI row from.
    const unexpected = rows
      .filter((r) => !r.skipped && (r.extra?.length ?? 0) > 0)
      .filter((r) => !(r.extra?.length === 1 && r.extra[0] === "users"))
      .map((r) => `${r.name}: ${r.extra?.join(", ")}`);
    expect(unexpected).toEqual([]);

    const withUsers = rows.filter((r) => r.extra?.includes("users"));
    expect(withUsers.length).toBeGreaterThan(0);
    for (const r of withUsers) expect(r.type).toBe("shadowsocks");
  });
});
