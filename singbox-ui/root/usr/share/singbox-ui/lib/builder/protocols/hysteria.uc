// lib/builder/protocols/hysteria.uc — Hysteria v1 outbound + inbound (E2 DSL).
// TLS mandatory; QUIC Fields (1.14+) shared block applies.
let reg = require("builder.protocols.registry");

reg.register({
    kind: "outbound", type: "hysteria", sing_box_type: "hysteria",
    shared: { tls: { force_enabled: true }, quic: {}, dial: true },
    fields: [
        { name: "server", type: "string", tab: "basic", required: true,
          validate: "host", ui_label: "Server", json_key: "server", omit_when: "never" },
        { name: "server_port", type: "number", tab: "basic", required: true,
          validate: "port", default: 443, ui_label: "Server port",
          json_key: "server_port", coerce: "num", omit_when: "never" },
        { name: "server_ports", type: "list", tab: "basic", ui_label: "Server ports (hop ranges)",
          placeholder: "2080:3000", advanced: true, json_key: "server_ports", coerce: "array" },
        { name: "hop_interval", type: "string", tab: "basic", ui_label: "Hop interval",
          placeholder: "30s", advanced: true, json_key: "hop_interval" },
        { name: "up_mbps", type: "number", tab: "basic", ui_label: "Uplink Mbps",
          placeholder: "100", json_key: "up_mbps", coerce: "num" },
        { name: "down_mbps", type: "number", tab: "basic", ui_label: "Downlink Mbps",
          placeholder: "100", json_key: "down_mbps", coerce: "num" },
        { name: "hysteria_auth_str", type: "string", tab: "basic", secret: true,
          ui_label: "Auth (auth_str)", json_key: "auth_str" },
        { name: "obfs", type: "string", tab: "basic", secret: true, ui_label: "Obfs password",
          advanced: true, json_key: "obfs" },
        { name: "network", type: "enum", tab: "basic", values: ["", "tcp", "udp"],
          ui_label: "Network", advanced: true, json_key: "network", only_values: ["tcp", "udp"] },
        { name: "recv_window_conn", type: "number", tab: "basic",
          ui_label: "Receive window conn (deprecated)", advanced: true,
          json_key: "recv_window_conn", coerce: "num" },
        { name: "recv_window", type: "number", tab: "basic",
          ui_label: "Receive window (deprecated)", advanced: true,
          json_key: "recv_window", coerce: "num" },
        { name: "disable_mtu_discovery", type: "bool", tab: "basic",
          ui_label: "Disable MTU discovery (deprecated)", advanced: true,
          json_key: "disable_mtu_discovery", coerce: "bool", max_version: "1.14" },
    ],
});

reg.register({
    kind: "inbound", type: "hysteria", sing_box_type: "hysteria",
    shared: { tls: { force_enabled: true }, quic: {} },
    fields: [
        { name: "listen", type: "string", tab: "basic", default: "::", ui_label: "Listen address" },
        { name: "listen_port", type: "number", tab: "basic", required: true,
          validate: "port", default: 443, ui_label: "Listen port" },
        { name: "up_mbps", type: "number", tab: "basic", ui_label: "Uplink Mbps",
          json_key: "up_mbps", coerce: "num" },
        { name: "down_mbps", type: "number", tab: "basic", ui_label: "Downlink Mbps",
          json_key: "down_mbps", coerce: "num" },
        { name: "obfs", type: "string", tab: "basic", secret: true, ui_label: "Obfs password",
          advanced: true, json_key: "obfs" },
        { name: "hysteria_user", type: "list", tab: "basic", secret: true,
          ui_label: "Users (name:auth_str)", placeholder: "alice:secret" },
    ],
    users: {
        from: "hysteria_user",
        columns: [ { key: "name", required: true }, { key: "auth_str", tail: true, always: true } ],
    },
});

return {};
