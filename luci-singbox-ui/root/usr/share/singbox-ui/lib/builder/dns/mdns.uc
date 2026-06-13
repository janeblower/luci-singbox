// lib/builder/dns/mdns.uc — mDNS server descriptor.
let reg = require("builder.protocols.registry");
reg.register({
    kind: "dns", type: "mdns", sing_box_type: "mdns",
    shared: { dial: {} },
    fields: [
        { name: "interface", type: "list", tab: "basic", dynamic: "devices",
          ui_label: "Interfaces", json_key: "interface", coerce: "array" },
    ],
});

return {};
