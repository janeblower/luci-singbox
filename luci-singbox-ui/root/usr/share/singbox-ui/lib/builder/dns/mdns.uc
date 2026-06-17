// lib/builder/dns/mdns.uc — mDNS server descriptor.
let reg = require("builder.protocols.registry");
reg.register({
    kind: "dns", type: "mdns", sing_box_type: "mdns",
    min_version: "1.14",   // mDNS DNS server introduced in sing-box 1.14
    shared: { dial: {} },
    fields: [
        { name: "interface", type: "list", tab: "basic", dynamic: "devices",
          ui_label: "Interfaces", json_key: "interface", coerce: "array" },
    ],
});

return {};
