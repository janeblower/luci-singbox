// lib/builder/settings/registry.uc — eager-loads singleton settings descriptors
// (cache, clash_api). Modules are added by their respective phases.
let reg = require("builder.protocols.registry");
let _modules = [];   // "builder.settings.clash_api", "builder.settings.cache"
for (let m in _modules) {
    try { require(m); }
    catch (e) { warn(sprintf("settings/registry: failed to load %s: %s\n", m, e)); }
}
return reg;
