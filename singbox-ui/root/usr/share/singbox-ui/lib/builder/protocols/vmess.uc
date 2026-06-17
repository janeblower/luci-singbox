// lib/builder/protocols/vmess.uc — VMess outbound + inbound (E2 DSL).
let reg = require("builder.protocols.registry");

const SECURITY = ["auto", "none", "zero", "aes-128-gcm", "chacha20-poly1305"];

reg.register({
    kind: "outbound", type: "vmess", sing_box_type: "vmess",
    shared: { tls: {}, transport: {}, multiplex: {}, dial: true },
    fields: [
        { name: "server", type: "string", tab: "basic", required: true,
          validate: "host", ui_label: "Server", json_key: "server", omit_when: "never" },
        { name: "server_port", type: "number", tab: "basic", required: true,
          validate: "port", default: 443, ui_label: "Server port",
          json_key: "server_port", coerce: "num", omit_when: "never" },
        { name: "server_uuid", type: "string", tab: "basic", required: true, secret: true,
          validate: "uuid", ui_label: "UUID", json_key: "uuid" },
        { name: "vmess_security", type: "enum", tab: "basic", values: SECURITY,
          default: "auto", default_when_empty: "auto", ui_label: "Security", json_key: "security" },
        { name: "alter_id", type: "number", tab: "basic", ui_label: "Alter ID", advanced: true,
          json_key: "alter_id", coerce: "num" },
        { name: "global_padding", type: "bool", tab: "basic", ui_label: "Global padding",
          advanced: true, json_key: "global_padding", coerce: "bool" },
        { name: "authenticated_length", type: "bool", tab: "basic", ui_label: "Authenticated length",
          advanced: true, json_key: "authenticated_length", coerce: "bool" },
        { name: "network", type: "enum", tab: "basic", values: ["", "tcp", "udp"],
          ui_label: "Network", advanced: true, json_key: "network", only_values: ["tcp", "udp"] },
        { name: "packet_encoding", type: "enum", tab: "basic", values: ["", "packetaddr", "xudp"],
          ui_label: "Packet encoding", advanced: true, json_key: "packet_encoding" },
    ],
});

reg.register({
    kind: "inbound", type: "vmess", sing_box_type: "vmess",
    shared: { tls: {}, transport: {}, multiplex: {} },
    fields: [
        { name: "listen", type: "string", tab: "basic", default: "::", ui_label: "Listen address" },
        { name: "listen_port", type: "number", tab: "basic", required: true,
          validate: "port", default: 443, ui_label: "Listen port" },
        { name: "vmess_user", type: "list", tab: "basic", secret: true,
          ui_label: "Users (name:uuid)", placeholder: "alice:11111111-..." },
        { name: "server_uuid", type: "string", tab: "basic", secret: true,
          validate: "uuid", ui_label: "UUID (single-user)" },
    ],
    users: {
        from: "vmess_user",
        columns: [ { key: "name", required: true }, { key: "uuid", required: true, guard: "uuid", tail: true } ],
        single_fallback: { fields: [ { key: "uuid", from: "server_uuid" } ] },
    },
});

return {};
