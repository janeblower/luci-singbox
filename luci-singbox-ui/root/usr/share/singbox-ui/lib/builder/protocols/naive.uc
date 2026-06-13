// lib/builder/protocols/naive.uc — NaiveProxy outbound (Since 1.13.0) + inbound.
let reg = require("builder.protocols.registry");

reg.register({
    kind: "outbound", type: "naive", sing_box_type: "naive",
    min_version: "1.13.0",
    shared: { tls: { force_enabled: true }, dial: true },
    fields: [
        { name: "server", type: "string", tab: "basic", required: true,
          validate: "host", ui_label: "Server", json_key: "server", omit_when: "never" },
        { name: "server_port", type: "number", tab: "basic", required: true,
          validate: "port", default: 443, ui_label: "Server port",
          json_key: "server_port", coerce: "num", omit_when: "never" },
        { name: "username", type: "string", tab: "basic", ui_label: "Username", json_key: "username" },
        { name: "password", type: "string", tab: "basic", secret: true, ui_label: "Password", json_key: "password" },
        { name: "network", type: "enum", tab: "basic", values: ["", "tcp", "udp"],
          ui_label: "Network", advanced: true, json_key: "network", only_values: ["tcp", "udp"] },
        { name: "insecure_concurrency", type: "number", tab: "basic",
          ui_label: "Insecure concurrency", advanced: true,
          json_key: "insecure_concurrency", coerce: "num" },
        { name: "quic_congestion_control", type: "string", tab: "basic",
          ui_label: "QUIC congestion control (1.13+)", advanced: true,
          json_key: "quic_congestion_control" },
    ],
});

reg.register({
    kind: "inbound", type: "naive", sing_box_type: "naive",
    shared: { tls: { force_enabled: true } },
    fields: [
        { name: "listen", type: "string", tab: "basic", default: "::", ui_label: "Listen address" },
        { name: "listen_port", type: "number", tab: "basic", required: true,
          validate: "port", default: 443, ui_label: "Listen port" },
        { name: "network", type: "enum", tab: "basic", values: ["", "udp", "tcp"],
          ui_label: "Network", json_key: "network", only_values: ["tcp", "udp"] },
        { name: "naive_user", type: "list", tab: "basic", secret: true,
          ui_label: "Users (username:password)", placeholder: "alice:secret" },
        { name: "quic_congestion_control", type: "string", tab: "basic",
          ui_label: "QUIC congestion control (1.13+)", advanced: true,
          json_key: "quic_congestion_control" },
    ],
    users: {
        from: "naive_user",
        columns: [ { key: "username", required: true }, { key: "password", tail: true, always: true } ],
    },
});

return {};
