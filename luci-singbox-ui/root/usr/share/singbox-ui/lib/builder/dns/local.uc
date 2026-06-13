// lib/builder/dns/local.uc — local system DNS resolver descriptor.
let reg = require("builder.protocols.registry");
reg.register({
    kind: "dns", type: "local", sing_box_type: "local",
    shared: { dial: {} },
    fields: [
        { name: "prefer_go", type: "bool", tab: "basic", default: 0,
          ui_label: "Prefer Go resolver", json_key: "prefer_go", coerce: "bool" },
    ],
});

return {};
