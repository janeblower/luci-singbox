// lib/builder/dns/fakeip.uc — FakeIP DNS server descriptor.
let reg = require("builder.protocols.registry");
reg.register({
    kind: "dns", type: "fakeip", sing_box_type: "fakeip",
    fields: [
        { name: "inet4_range", type: "string", tab: "basic", placeholder: "198.18.0.0/15",
          ui_label: "IPv4 range", json_key: "inet4_range" },
        { name: "inet6_range", type: "string", tab: "basic", placeholder: "fc00::/18",
          ui_label: "IPv6 range", json_key: "inet6_range" },
    ],
});

return {};
