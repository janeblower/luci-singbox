// lib/builder/dns_rule/logical.uc — dns_rule:logical. `rules` references default
// dns_rule sections; dns.uc inlines them as headless matchers. `type:"logical"`
// is set by dns.uc, not the filler. `rules` is UI-only (no json_key).
let reg    = require("builder.protocols.registry");
let action = require("builder._shared.dns_action");
reg.register({
    kind: "dns_rule", type: "logical", sing_box_type: "logical",
    fields: [
        { name: "mode", type: "enum", tab: "match", required: true,
          json_key: "mode", values: [ "and", "or" ], default: "or", ui_label: "Mode" },
        { name: "rules", type: "list", tab: "match", dynamic: "dns_rules",
          ui_label: "Sub-rules" },
        { name: "invert", type: "bool", tab: "match", advanced: true,
          json_key: "invert", coerce: "bool", ui_label: "Invert" },
        ...action.fields(),
    ],
});
return {};
