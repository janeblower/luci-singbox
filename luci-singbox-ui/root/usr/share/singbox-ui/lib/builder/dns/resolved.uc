// lib/builder/dns/resolved.uc — systemd-resolved DNS server descriptor.
let reg = require("builder.protocols.registry");
reg.register({
    kind: "dns", type: "resolved", sing_box_type: "resolved",
    fields: [
        { name: "service", type: "string", tab: "basic", required: true,
          ui_label: "Service tag", json_key: "service", omit_when: "never" },
        { name: "accept_default_resolvers", type: "bool", tab: "basic", default: 0,
          ui_label: "Accept default resolvers", json_key: "accept_default_resolvers", coerce: "bool" },
    ],
});

return {};
