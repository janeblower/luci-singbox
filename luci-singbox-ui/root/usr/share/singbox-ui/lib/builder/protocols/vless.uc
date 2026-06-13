// lib/protocols/vless.uc — VLESS outbound + inbound under the E2 DSL.

let reg = require("builder.protocols.registry");

// --- Outbound ------------------------------------------------------------

reg.register({
    kind: "outbound", type: "vless", sing_box_type: "vless",
    shared: { tls: {}, transport: {}, multiplex: {}, dial: {} },

    fields: [
        { name: "server", type: "string", tab: "basic", required: true,
          validate: "host", ui_label: "Server",
          json_key: "server", omit_when: "never" },
        { name: "server_port", type: "number", tab: "basic", required: true,
          validate: "port", ui_label: "Server port", default: 443,
          json_key: "server_port", coerce: "num", omit_when: "never" },
        { name: "server_uuid", type: "string", tab: "basic", required: true,
          secret: true, validate: "uuid", ui_label: "UUID",
          json_key: "uuid" },
        { name: "vless_flow", type: "enum", tab: "basic",
          values: ["", "xtls-rprx-vision"], ui_label: "Flow",
          json_key: "flow" },
        { name: "network", type: "enum", tab: "basic",
          values: ["tcp", "udp"], default: "tcp", ui_label: "Network",
          json_key: "network", skip_value: "tcp" },
        { name: "packet_encoding", type: "enum", tab: "basic",
          values: ["", "packetaddr", "xudp"], ui_label: "Packet encoding",
          depends: { field: "network", value: "udp" },
          json_key: "packet_encoding", requires: { field: "network", value: "udp" } },
    ],
});

// --- Inbound -------------------------------------------------------------

reg.register({
    kind: "inbound", type: "vless", sing_box_type: "vless",
    shared: { tls: {}, transport: {}, multiplex: {} },

    fields: [
        { name: "listen", type: "string", tab: "basic", default: "::",
          ui_label: "Listen address" },
        { name: "listen_port", type: "number", tab: "basic", required: true,
          validate: "port", ui_label: "Listen port" },
        { name: "inbound_user", type: "list", tab: "basic", secret: true,
          ui_label: "Users (name:uuid[:flow])",
          placeholder: "alice:11111111-...:xtls-rprx-vision" },
        { name: "server_uuid", type: "string", tab: "basic", secret: true,
          validate: "uuid", ui_label: "UUID (single-user)" },
        { name: "vless_flow", type: "enum", tab: "basic",
          values: ["", "xtls-rprx-vision"], ui_label: "Flow (single-user)" },
    ],

    users: {
        from: "inbound_user",
        columns: [
            { key: "name", required: true },
            { key: "uuid", required: true, guard: "uuid" },
            { key: "flow", tail: true },
        ],
        single_fallback: {
            fields: [
                { key: "uuid", from: "server_uuid" },
                { key: "flow", from: "vless_flow" },
            ],
        },
    },
});

return {};
