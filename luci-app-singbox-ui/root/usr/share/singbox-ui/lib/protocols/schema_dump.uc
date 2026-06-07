// lib/protocols/schema_dump.uc — projects the descriptor registry to a
// declarative JSON-safe object. `emit` functions are explicitly dropped:
// the whitelist below contains only declarative keys.

const WHITELIST = [
    "name", "type", "required", "default", "validate",
    "group", "ui_label", "secret", "values", "item",
];

function project_field(f) {
    let out = {};
    for (let k in WHITELIST)
        if (f[k] != null) out[k] = f[k];
    return out;
}

function project_descriptor(d) {
    let fields = [];
    for (let f in d.fields) push(fields, project_field(f));
    return { sing_box_type: d.sing_box_type, fields: fields };
}

function dump_all() {
    let reg = require("protocols.registry");
    let out = { outbound: {}, inbound: {} };
    for (let k in [ "outbound", "inbound" ])
        for (let proto in reg.types_for_kind(k))
            out[k][proto] = project_descriptor(reg.get(k, proto));
    return out;
}

return { dump_all, WHITELIST };
