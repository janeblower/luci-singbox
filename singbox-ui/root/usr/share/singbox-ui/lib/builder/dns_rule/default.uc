// lib/builder/dns_rule/default.uc — dns_rule:default = full matchers + action.
let reg    = require("builder.protocols.registry");
let match  = require("builder._shared.match");
let action = require("builder._shared.dns_action");
reg.register({
    kind: "dns_rule", type: "default", sing_box_type: "default",
    fields: [ ...match.fields("dns"), ...action.fields() ],
});
return {};
