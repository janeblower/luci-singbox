// lib/builder/dns_rule/registry.uc — eager-load every dns_rule descriptor (so
// its register() fires), then re-export the shared protocol registry surface.
let reg = require("builder.protocols.registry");
reg.require_dir("dns_rule");
return reg;
