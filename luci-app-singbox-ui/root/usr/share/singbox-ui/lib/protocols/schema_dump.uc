// lib/protocols/schema_dump.uc

const FIELD_WHITELIST = [
    "name", "type", "tab", "required", "default", "validate",
    "ui_label", "secret", "values", "item",
    "advanced", "depends", "parent_enabled", "placeholder", "virtual",
];

function project_field(f) {
    let out = {};
    for (let k in FIELD_WHITELIST)
        if (f[k] != null) out[k] = f[k];
    return out;
}

function project_materialized(m) {
    let fields = [];
    for (let f in m.fields) push(fields, project_field(f));
    return {
        sing_box_type: m.sing_box_type,
        tabs: m.tabs,
        shared: m.shared,
        fields: fields,
    };
}

function dump_all() {
    let reg = require("protocols.registry");
    let out = { outbound: {}, inbound: {} };
    for (let k in [ "outbound", "inbound" ])
        for (let proto in reg.types_for_kind(k)) {
            let m = reg.materialize(k, proto);
            if (m != null) out[k][proto] = project_materialized(m);
        }
    return out;
}

return { dump_all, FIELD_WHITELIST };
