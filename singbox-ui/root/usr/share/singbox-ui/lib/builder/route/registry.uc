// lib/builder/route/registry.uc — eager-loads route_rule + rule_set descriptors
// so their register() fires, then re-exports the shared protocol registry.
let reg = require("builder.protocols.registry");
let _modules = [
    "builder.route.default", "builder.route.logical",
    "builder.route.ruleset_remote", "builder.route.ruleset_local",
    "builder.route.ruleset_inline",
];
for (let m in _modules) {
    try { require(m); }
    catch (e) { warn(sprintf("route/registry: failed to load %s: %s\n", m, e)); }
}
return reg;
