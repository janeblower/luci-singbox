// lib/builder/dns/legacy.uc — legacy address-string DNS server descriptor.
// sing_box_type is intentionally empty; post() removes the type key from output
// so sing-box parses the address string instead of a typed server object.
let reg = require("builder.protocols.registry");
reg.register({
    kind: "dns", type: "legacy", sing_box_type: "",
    fields: [
        { name: "address", type: "string", tab: "basic", required: true,
          ui_label: "Address (with scheme)", placeholder: "tls://1.1.1.1",
          json_key: "address", omit_when: "never" },
        { name: "address_resolver", type: "string", tab: "basic", dynamic: "dns_servers",
          ui_label: "Address resolver (tag)", json_key: "address_resolver" },
        { name: "address_strategy", type: "enum", tab: "basic",
          values: ["", "prefer_ipv4", "prefer_ipv6", "ipv4_only", "ipv6_only"],
          ui_label: "Address strategy", json_key: "address_strategy" },
        { name: "strategy", type: "enum", tab: "basic",
          values: ["", "prefer_ipv4", "prefer_ipv6", "ipv4_only", "ipv6_only"],
          ui_label: "Strategy", json_key: "strategy" },
        { name: "detour", type: "string", tab: "basic", dynamic: "outbounds",
          ui_label: "Detour (outbound tag)", json_key: "detour" },
        { name: "client_subnet", type: "string", tab: "basic",
          ui_label: "Client subnet", json_key: "client_subnet" },
    ],
    post: function(out, s) { delete out.type; },
});

return {};
