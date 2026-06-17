// lib/builder/dns/tls.uc — DNS-over-TLS server descriptor.
let reg = require("builder.protocols.registry");
reg.register({
    kind: "dns", type: "tls", sing_box_type: "tls",
    shared: { dial: {}, tls: {} },
    fields: [
        { name: "server", type: "string", tab: "basic", required: true, validate: "host",
          ui_label: "Server", json_key: "server", omit_when: "never" },
        { name: "server_port", type: "number", tab: "basic", default: 853, validate: "port",
          ui_label: "Server port", json_key: "server_port", coerce: "num" },
        { name: "domain_resolver", type: "string", tab: "basic", dynamic: "dns_servers",
          ui_label: "Domain resolver (tag)", json_key: "domain_resolver" },
    ],
});

return {};
