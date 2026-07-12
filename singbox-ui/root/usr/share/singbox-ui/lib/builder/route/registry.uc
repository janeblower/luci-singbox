// lib/builder/route/registry.uc — eager-load every route_rule/rule_set descriptor
// (so its register() fires), then re-export the shared protocol registry surface.
let reg = require("builder.protocols.registry");
reg.require_dir("route");
return reg;
