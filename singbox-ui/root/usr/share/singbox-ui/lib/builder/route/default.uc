// lib/builder/route/default.uc — route_rule:default = full matchers + action.
let reg    = require("builder.protocols.registry");
let match  = require("builder._shared.match");
let action = require("builder._shared.route_action");
reg.register({
    kind: "route_rule", type: "default", sing_box_type: "default",
    fields: [ ...match.fields("route"), ...action.fields() ],
});
return {};
