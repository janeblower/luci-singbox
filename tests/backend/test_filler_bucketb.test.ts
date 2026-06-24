import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

// Regression coverage for the bucket-B filler edge-cases (eng-1, eng-3).
describe("filler bucket-B edge cases", () => {
  useGuest();

  it("eng-1: default_when_empty is applied BEFORE the only_values whitelist (str)", async () => {
    // A field with BOTH only_values and default_when_empty: an empty input must
    // fall back to the default (which is itself in only_values) and emit, not be
    // dropped by the whitelist check running first.
    const r = await runUcode(`
let f = require("builder._filler");
let d = { kind:"outbound", sing_box_type:"x", fields:[
    { name:"mode", type:"string", json_key:"mode", only_values:["a","b"], default_when_empty:"a" },
], shared:null };
print(sprintf("%J", f.build(d, { [".name"]:"t", mode:"" })));
`);
    expect(r.exitCode).toBe(0);
    // New order: "" -> default "a" -> passes only_values -> emitted.
    expect(JSON.parse(r.stdout).mode).toBe("a");
  });

  it("eng-3: a gated group with only-empty optional fields does NOT emit key:{}", async () => {
    const r = await runUcode(`
let f = require("builder._filler");
let d = { kind:"outbound", sing_box_type:"x", fields:[],
    groups:[ { json_key:"grp", gate:{ flag:"on" }, fields:[
        { name:"opt", type:"string", json_key:"opt" },
    ] } ], shared:null };
print(sprintf("%J", f.build(d, { [".name"]:"t", on:"1" })));
`);
    expect(r.exitCode).toBe(0);
    const out = JSON.parse(r.stdout);
    // Gate passes (on=1) but the only child is empty, so the empty object is
    // suppressed rather than emitting "grp": {}.
    expect("grp" in out).toBe(false);
  });

  it("eng-3: a gated group with a present child still emits the object", async () => {
    const r = await runUcode(`
let f = require("builder._filler");
let d = { kind:"outbound", sing_box_type:"x", fields:[],
    groups:[ { json_key:"grp", gate:{ flag:"on" }, fields:[
        { name:"opt", type:"string", json_key:"opt" },
    ] } ], shared:null };
print(sprintf("%J", f.build(d, { [".name"]:"t", on:"1", opt:"v" })));
`);
    expect(r.exitCode).toBe(0);
    expect(JSON.parse(r.stdout).grp).toEqual({ opt: "v" });
  });
});
