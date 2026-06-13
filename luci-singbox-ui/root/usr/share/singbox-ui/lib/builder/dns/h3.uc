// lib/builder/dns/h3.uc — DNS-over-HTTP/3 server descriptor.
let reg = require("builder.protocols.registry");
reg.register({
    kind: "dns", type: "h3", sing_box_type: "h3",
    shared: { dial: {}, tls: {} },
    fields: [
        { name: "server", type: "string", tab: "basic", required: true, validate: "host",
          ui_label: "Server", json_key: "server", omit_when: "never" },
        { name: "server_port", type: "number", tab: "basic", default: 443, validate: "port",
          ui_label: "Server port", json_key: "server_port", coerce: "num" },
        { name: "path", type: "string", tab: "basic", placeholder: "/dns-query",
          ui_label: "Path", json_key: "path" },
        { name: "domain_resolver", type: "string", tab: "basic", dynamic: "dns_servers",
          ui_label: "Domain resolver (tag)", json_key: "domain_resolver" },
    ],
});

return {};
