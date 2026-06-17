// lib/builder/dns_rule/registry.uc — eager-loads dns_rule descriptors
// (default, logical). Modules are added by Phase 3.
let reg = require("builder.protocols.registry");
let _modules = [ "builder.dns_rule.default", "builder.dns_rule.logical" ];
for (let m in _modules) {
    try { require(m); }
    catch (e) { warn(sprintf("dns_rule/registry: failed to load %s: %s\n", m, e)); }
}
return reg;
