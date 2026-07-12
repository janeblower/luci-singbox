// lib/builder/settings/registry.uc — eager-load every singleton settings descriptor
// (so its register() fires), then re-export the shared protocol registry surface.
let reg = require("builder.protocols.registry");
reg.require_dir("settings");
return reg;
