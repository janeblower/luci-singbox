// lib/builder/dns/dhcp.uc — DHCP-sourced DNS server descriptor.
let reg = require("builder.protocols.registry");
reg.register({
    kind: "dns", type: "dhcp", sing_box_type: "dhcp",
    shared: { dial: {} },
    fields: [
        { name: "interface", type: "string", tab: "basic", placeholder: "auto", dynamic: "devices",
          ui_label: "Interface", json_key: "interface" },
    ],
});

return {};
