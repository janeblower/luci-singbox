// lib/builder/dns/tailscale.uc — Tailscale DNS server descriptor.
let reg = require("builder.protocols.registry");
reg.register({
    kind: "dns", type: "tailscale", sing_box_type: "tailscale",
    fields: [
        { name: "endpoint", type: "string", tab: "basic", required: true,
          ui_label: "Endpoint tag", json_key: "endpoint", omit_when: "never" },
        { name: "accept_default_resolvers", type: "bool", tab: "basic", default: 0,
          ui_label: "Accept default resolvers", json_key: "accept_default_resolvers", coerce: "bool" },
        { name: "accept_search_domain", type: "bool", tab: "basic", default: 0,
          ui_label: "Accept search domain", json_key: "accept_search_domain", coerce: "bool",
          min_version: "1.14" },
    ],
});

return {};
