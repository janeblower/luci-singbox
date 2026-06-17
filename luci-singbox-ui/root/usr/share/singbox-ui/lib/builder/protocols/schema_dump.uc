// lib/protocols/schema_dump.uc

const FIELD_WHITELIST = [
    "name", "type", "tab", "required", "default", "validate",
    "ui_label", "ui_help", "secret", "values", "item", "dynamic",
    "advanced", "depends", "parent_enabled", "placeholder", "virtual",
    "multiline", "min_version", "max_version", "exclusive",
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
    require("builder.dns.registry");     // dns servers
    require("builder.route.registry");   // route_rule / rule_set
    require("builder.dns_rule.registry");// dns_rule (default/logical)
    require("builder.settings.registry");// cache + clash_api singletons
    let kinds = [ "outbound", "inbound", "dns", "route_rule", "rule_set",
                  "dns_rule", "cache", "clash_api" ];
    let out = {};
    for (let k in kinds) out[k] = {};
    for (let k in kinds)
        for (let proto in reg.types_for_kind(k)) {
            let m = reg.materialize(k, proto);
            if (m != null) out[k][proto] = project_materialized(m);
        }
    return out;
}

return { dump_all, FIELD_WHITELIST };
