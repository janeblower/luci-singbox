// lib/builder/protocols/tuic.uc — TUIC outbound + inbound (E2 DSL).
let reg = require("builder.protocols.registry");

const CC = ["", "cubic", "new_reno", "bbr"];

reg.register({
    kind: "outbound", type: "tuic", sing_box_type: "tuic",
    shared: { tls: { force_enabled: true }, quic: {}, dial: true },
    fields: [
        { name: "server", type: "string", tab: "basic", required: true,
          validate: "host", ui_label: "Server", json_key: "server", omit_when: "never" },
        { name: "server_port", type: "number", tab: "basic", required: true,
          validate: "port", default: 443, ui_label: "Server port",
          json_key: "server_port", coerce: "num", omit_when: "never" },
        { name: "server_uuid", type: "string", tab: "basic", required: true, secret: true,
          validate: "uuid", ui_label: "UUID", json_key: "uuid" },
        { name: "server_password", type: "string", tab: "basic", secret: true,
          ui_label: "Password", json_key: "password" },
        { name: "congestion_control", type: "enum", tab: "basic", values: CC,
          ui_label: "Congestion control", json_key: "congestion_control" },
        { name: "udp_relay_mode", type: "enum", tab: "basic", values: ["", "native", "quic"],
          ui_label: "UDP relay mode", advanced: true, json_key: "udp_relay_mode" },
        { name: "udp_over_stream", type: "bool", tab: "basic", ui_label: "UDP over stream",
          advanced: true, json_key: "udp_over_stream", coerce: "bool" },
        { name: "zero_rtt_handshake", type: "bool", tab: "basic", ui_label: "Zero-RTT handshake",
          advanced: true, json_key: "zero_rtt_handshake", coerce: "bool" },
        { name: "heartbeat", type: "string", tab: "basic", ui_label: "Heartbeat",
          placeholder: "10s", advanced: true, json_key: "heartbeat" },
        { name: "network", type: "enum", tab: "basic", values: ["", "tcp", "udp"],
          ui_label: "Network", advanced: true, json_key: "network", only_values: ["tcp", "udp"] },
    ],
});

reg.register({
    kind: "inbound", type: "tuic", sing_box_type: "tuic",
    shared: { tls: { force_enabled: true }, quic: {} },
    fields: [
        { name: "listen", type: "string", tab: "basic", default: "::", ui_label: "Listen address" },
        { name: "listen_port", type: "number", tab: "basic", required: true,
          validate: "port", default: 443, ui_label: "Listen port" },
        { name: "tuic_user", type: "list", tab: "basic", secret: true,
          ui_label: "Users (name:uuid:password)", placeholder: "alice:uuid:pw" },
        { name: "congestion_control", type: "enum", tab: "basic", values: CC,
          ui_label: "Congestion control", json_key: "congestion_control" },
        { name: "auth_timeout", type: "string", tab: "basic", ui_label: "Auth timeout",
          placeholder: "3s", advanced: true, json_key: "auth_timeout" },
        { name: "zero_rtt_handshake", type: "bool", tab: "basic", ui_label: "Zero-RTT handshake",
          advanced: true, json_key: "zero_rtt_handshake", coerce: "bool" },
        { name: "heartbeat", type: "string", tab: "basic", ui_label: "Heartbeat",
          placeholder: "10s", advanced: true, json_key: "heartbeat" },
    ],
    users: {
        from: "tuic_user",
        columns: [
            { key: "name", required: true },
            { key: "uuid", required: true, guard: "uuid" },
            { key: "password", always: true },
        ],
    },
});

return {};
