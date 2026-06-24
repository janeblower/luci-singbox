// lib/builder/route/logical.uc — route_rule:logical. `rules` references default
// route_rule sections; route.uc inlines them as headless matchers (so `rules`
// is UI-only: no json_key). `type:"logical"` is set by route.uc, not the filler.
let reg    = require("builder.protocols.registry");
let action = require("builder._shared.route_action");
reg.register({
    kind: "route_rule", type: "logical", sing_box_type: "logical",
    fields: [
        { name: "mode", type: "enum", tab: "match", required: true,
          json_key: "mode", values: [ "and", "or" ], default: "or",
          default_when_empty: "or", ui_label: "Mode" },
        { name: "rules", type: "list", tab: "match", dynamic: "route_rules",
          ui_label: "Sub-rules" },
        { name: "invert", type: "bool", tab: "match", advanced: true,
          json_key: "invert", coerce: "bool", ui_label: "Invert" },
        ...action.fields(),
    ],
});
return {};
