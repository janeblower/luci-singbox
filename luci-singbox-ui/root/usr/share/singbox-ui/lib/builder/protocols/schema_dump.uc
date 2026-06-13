// lib/protocols/schema_dump.uc

const FIELD_WHITELIST = [
    "name", "type", "tab", "required", "default", "validate",
    "ui_label", "secret", "values", "item", "dynamic",
    "advanced", "depends", "parent_enabled", "placeholder", "virtual",
    "multiline",
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
    let out = {
        sing_box_type: m.sing_box_type,
        tabs: m.tabs,
        shared: m.shared,
        fields: fields,
    };
    out.min_version = m.min_version ?? "";
    return out;
}

function dump_all() {
    let reg = require("builder.protocols.registry");
    require("builder.dns.registry");   // ensure dns descriptors are registered
    let out = { outbound: {}, inbound: {}, dns: {} };
    for (let k in [ "outbound", "inbound", "dns" ])
        for (let proto in reg.types_for_kind(k)) {
            let m = reg.materialize(k, proto);
            if (m != null) out[k][proto] = project_materialized(m);
        }
    return out;
}

return { dump_all, FIELD_WHITELIST };
