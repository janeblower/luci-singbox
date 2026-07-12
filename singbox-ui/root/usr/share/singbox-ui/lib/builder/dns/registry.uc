// lib/builder/dns/registry.uc — eager-load every DNS server descriptor (so its
// register() fires), then re-export the shared protocol registry surface.
let reg = require("builder.protocols.registry");
reg.require_dir("dns");
return reg;
