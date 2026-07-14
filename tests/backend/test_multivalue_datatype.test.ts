import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

// A list WITH choices renders as form.MultiValue (task 7: the checkbox dropdown).
// Verified against the form.js in the running container, NOT master:
//
//     CBIDynamicList.renderWidget -> new ui.DynamicList(..., { datatype: this.datatype, ... })
//     CBIMultiValue.renderWidget  -> new ui.Dropdown(...,   { /* no datatype */ ... })
//
// So `opt.datatype` is silently DROPPED on a MultiValue. descriptor_form's
// attachValidator() sends a `validate:` name down one of two roads: a name in its
// DATATYPE map becomes `opt.datatype` (LuCI's own validation.js check), anything
// else becomes an `opt.validate` function from lib/validators.js — and THAT one
// survives, because both widgets go through getValidator(). tls_alpn's
// validate:"alpn" is the second kind, which is why the only list-with-choices we
// ship is still validated.
//
// There are zero broken instances today, and a datatype bridge for zero callers
// would be dead code. This guard is the cheap half: the day a descriptor says
// `{ type: "list", values: [...], validate: "host" }` — a DATATYPE name — the lane
// goes red instead of the field losing its validation in silence.
//
// The DATATYPE names are READ from descriptor_form.js, not restated here: a name
// added to that map is exactly what would make a new descriptor field unsafe.
const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const DESCRIPTOR_FORM_JS = `${WORK}/luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/lib/descriptor_form.js`;

describe("MultiValue drops opt.datatype", () => {
  useGuest();

  it("no list-with-choices field declares a DATATYPE validator", async () => {
    const src = `
require("outbound");
require("inbound");
require("builder.protocols.schema_dump").dump_all();  // dns / route / dns_rule / settings
let fs  = require("fs");
let reg = require("builder.protocols.registry");

let js = fs.readfile("${DESCRIPTOR_FORM_JS}");
let m  = match(js, /var DATATYPE = \\{([^}]*)\\}/);
if (m == null) { print("NO_DATATYPE_MAP\\n"); exit(0); }
let datatypes = {};
for (let k in match(m[1], /([a-zA-Z_]+) *:/g)) datatypes[k[1]] = true;
if (!length(datatypes)) { print("EMPTY_DATATYPE_MAP\\n"); exit(0); }

let bad = [];
function walk(ctx, fields) {
    for (let f in (fields || [])) {
        if (f.fields != null) walk(ctx, f.fields);
        if (f.type !== "list") continue;
        // Both roads to form.MultiValue: a static \`values\` list and a \`dynamic\`
        // source (rulesets / devices / outbounds / ...).
        if (f.values == null && f.dynamic == null) continue;
        if (f.validate != null && datatypes[f.validate])
            push(bad, sprintf("%s.%s validate:%s", ctx, f.name, f.validate));
    }
}
for (let ctx in reg._registry) {
    let d = reg._registry[ctx];
    walk(ctx, (reg.materialize(d.kind, d.type) ?? d).fields);   // own + shared-block fields
    for (let g in (d.groups || [])) walk(ctx, g.fields);
}
print(sprintf("DATATYPES %s\\n", join(",", sort(keys(datatypes)))));
for (let b in sort(bad)) print(sprintf("BAD %s\\n", b));
print(length(bad) ? "FAIL\\n" : "OK\\n");
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    // The map really was read — an empty/unparsed one would pass the walk vacuously.
    expect(r.stdout).toContain("DATATYPES host,port");
    expect(r.stdout.trim().split("\n").pop()).toBe("OK");
  });
});
