// lib/protocols/shadowsocks.uc — Shadowsocks outbound + inbound (E2 DSL).

let reg = require("builder.protocols.registry");

const METHODS = [
    "none", "aes-128-gcm", "aes-192-gcm", "aes-256-gcm",
    "chacha20-ietf-poly1305", "xchacha20-ietf-poly1305",
    "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm",
    "2022-blake3-chacha20-poly1305",
];

reg.register({
    kind: "outbound", type: "shadowsocks", sing_box_type: "shadowsocks",
    shared: { multiplex: {}, dial: true },

    fields: [
        { name: "server", type: "string", tab: "basic", required: true,
          validate: "host", ui_label: "Server",
          json_key: "server", omit_when: "never" },
        { name: "server_port", type: "number", tab: "basic", required: true,
          validate: "port", ui_label: "Server port",
          json_key: "server_port", coerce: "num", omit_when: "never" },
        { name: "shadowsocks_method", type: "enum", tab: "basic", required: true,
          values: METHODS, default: "2022-blake3-aes-128-gcm", ui_label: "Method",
          json_key: "method", omit_when: "never" },
        { name: "server_password", type: "string", tab: "basic", required: true,
          secret: true, ui_label: "Password",
          json_key: "password", omit_when: "never" },
        { name: "plugin", type: "string", tab: "basic", ui_label: "Plugin",
          values: ["obfs-local", "v2ray-plugin", "shadow-tls"], advanced: true,
          json_key: "plugin" },
        { name: "plugin_opts", type: "string", tab: "basic", ui_label: "Plugin opts", advanced: true,
          json_key: "plugin_opts", requires: "plugin" },
        { name: "network", type: "enum", tab: "basic",
          values: ["", "tcp", "udp"], ui_label: "Network", advanced: true,
          json_key: "network" },
        { name: "udp_over_tcp", type: "bool", tab: "basic", ui_label: "UDP over TCP", advanced: true,
          json_key: "udp_over_tcp", coerce: "bool" },
    ],
});

reg.register({
    kind: "inbound", type: "shadowsocks", sing_box_type: "shadowsocks",
    shared: { multiplex: {} },

    fields: [
        { name: "listen", type: "string", tab: "basic", default: "::",
          ui_label: "Listen address" },
        { name: "listen_port", type: "number", tab: "basic", required: true,
          validate: "port", ui_label: "Listen port" },
        { name: "shadowsocks_method", type: "enum", tab: "basic", required: true,
          values: METHODS, default: "2022-blake3-aes-128-gcm", ui_label: "Method",
          json_key: "method", omit_when: "never" },
        { name: "server_password", type: "string", tab: "basic", required: true,
          secret: true, ui_label: "Password",
          json_key: "password", omit_when: "never" },
        { name: "ss_user", type: "list", tab: "basic", secret: true,
          ui_label: "Users (name:method:password)",
          placeholder: "alice:2022-blake3-aes-128-gcm:base64==", advanced: true },
        { name: "network", type: "enum", tab: "basic",
          values: ["", "tcp", "udp"], ui_label: "Network", advanced: true,
          json_key: "network" },
    ],

    users: {
        from: "ss_user",
        columns: [
            { key: "name", required: true },
            { key: "method", validate: METHODS, discard: true },
            { key: "password", tail: true, warn_if_empty: true },
        ],
        clear_on_multi: [ "password" ],
    },
});

return {};
