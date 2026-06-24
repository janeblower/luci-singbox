// lib/builder/protocols/socks.uc — SOCKS outbound + inbound (E2 DSL).
let reg = require("builder.protocols.registry");

reg.register({
    kind: "outbound", type: "socks", sing_box_type: "socks",
    shared: { dial: true },
    fields: [
        { name: "server", type: "string", tab: "basic", required: true,
          validate: "host", ui_label: "Server", json_key: "server", omit_when: "never" },
        { name: "server_port", type: "number", tab: "basic", required: true,
          validate: "port", default: 1080, ui_label: "Server port",
          json_key: "server_port", coerce: "num", omit_when: "never" },
        { name: "socks_version", type: "enum", tab: "basic",
          values: ["5", "4", "4a"], default: "5", ui_label: "SOCKS version",
          json_key: "version", default_when_empty: "5" },
        { name: "username", type: "string", tab: "basic", ui_label: "Username",
          json_key: "username" },
        { name: "server_password", type: "string", tab: "basic", secret: true, ui_label: "Password",
          json_key: "password" },
        { name: "network", type: "enum", tab: "basic", values: ["", "tcp", "udp"],
          ui_label: "Network", advanced: true, json_key: "network", only_values: ["tcp", "udp"] },
        { name: "udp_over_tcp", type: "bool", tab: "basic", ui_label: "UDP over TCP",
          advanced: true, json_key: "udp_over_tcp", coerce: "bool" },
    ],
});

reg.register({
    kind: "inbound", type: "socks", sing_box_type: "socks",
    fields: [
        { name: "listen", type: "string", tab: "basic", default: "::", ui_label: "Listen address" },
        { name: "listen_port", type: "number", tab: "basic", required: true,
          validate: "port", default: 1080, ui_label: "Listen port" },
        { name: "socks_user", type: "list", tab: "basic", secret: true,
          ui_label: "Users (username:password)", placeholder: "alice:secret" },
    ],
    users: {
        from: "socks_user",
        columns: [ { key: "username", required: true }, { key: "password", always: true } ],
    },
});

return {};
