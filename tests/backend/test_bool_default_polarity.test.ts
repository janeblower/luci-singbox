import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode, runUcodeJSON } from "../helpers/ucode.ts";

// REGRESSION GUARD (tun auto_route/auto_redirect shipped with default:1).
//
// LuCI's CBIAbstractValue.parse() (verified against the form.js in the running
// OpenWrt container, NOT master) does:
//     if (fval == this.default && (this.optional || this.rmempty))
//         return this.remove(section_id);
// and rmempty defaults to true for every non-required field. So an option whose
// submitted value EQUALS its declared default is DELETED from UCI, never written.
//
// _filler's bool branch emits the key only when the UCI value is exactly "1".
// Put those two together and a bool that is BOTH emitted (json_key + coerce:bool)
// AND declared default:1 can never be emitted at all: ticking the box (== default)
// removes the option, and an absent option emits nothing. tun's auto_route did
// exactly this — the UI said "on", the config had no auto_route, the tun routed
// nothing, while the ownership predicates (which read unset as ON) still switched
// the tproxy inbound's nftables rules off. Silent total loss of interception.
//
// Rule: an EMITTED bool must default to 0, so that unset == OFF everywhere.
// (tproxy.nft_rules / dns fakeip.nft_rules keep default:1 legitimately — they have
// no json_key, are never emitted, and are read with `!== "0"`. No disagreement to
// have.)

describe("emitted bool defaults", () => {
  useGuest();

  it("no emitted bool field declares default:1 (LuCI would delete it from UCI)", async () => {
    const src = `
require("outbound");
require("inbound");
require("builder.protocols.schema_dump").dump_all();  // dns / route / dns_rule / settings
let reg = require("builder.protocols.registry");

let bad = [];
function walk(ctx, fields) {
    for (let f in (fields || [])) {
        if (f.fields != null) walk(ctx, f.fields);       // group / seq nesting
        if (f.json_key == null || f.coerce !== "bool") continue;
        if (f.default) push(bad, sprintf("%s.%s", ctx, f.name));
    }
}
for (let ctx in reg._registry) {
    let d = reg._registry[ctx];
    walk(ctx, (reg.materialize(d.kind, d.type) ?? d).fields);   // own + shared-block fields
    for (let g in (d.groups || [])) walk(ctx, g.fields);
}
for (let b in sort(bad)) print(sprintf("BAD %s\\n", b));
print(length(bad) ? "FAIL\\n" : "OK\\n");
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("OK");
  });

  it("tun: unset auto_route emits nothing; set auto_route emits it and opens its gates", async () => {
    const src = `
let inb = require("inbound");
print(sprintf("%J\\n", {
    unset: inb.build_one({ ".name": "t1", protocol: "tun", address: ["172.19.0.1/30"],
                           auto_redirect: "1", strict_route: "1", route_address: ["10.0.0.0/8"] }),
    set:   inb.build_one({ ".name": "t2", protocol: "tun", address: ["172.19.0.1/30"],
                           auto_route: "1", auto_redirect: "1", strict_route: "1",
                           route_address: ["10.0.0.0/8"] }),
}));
`;
    const out = await runUcodeJSON<{
      unset: Record<string, unknown>;
      set: Record<string, unknown>;
    }>(src);

    // Unset (what LuCI leaves behind when the box is left at its default) must not
    // look like routing — and must not drag its dependants along either.
    expect(out.unset).toEqual({
      type: "tun",
      tag: "t1",
      address: ["172.19.0.1/30"],
    });

    // Explicitly ticked: emitted, and the `requires`-gated siblings emit too.
    expect(out.set.auto_route).toBe(true);
    expect(out.set.auto_redirect).toBe(true);
    expect(out.set.strict_route).toBe(true);
    expect(out.set.route_address).toEqual(["10.0.0.0/8"]);
  });
});
