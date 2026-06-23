// lib/builder/protocols/shadowtls.uc — ShadowTLS outbound + inbound (E2 DSL).
// `handshake` is a nested {server, server_port} group. wildcard_sni since 1.12.
let reg = require("builder.protocols.registry");

reg.register({
    kind: "outbound", type: "shadowtls", sing_box_type: "shadowtls",
    shared: { tls: { force_enabled: true }, dial: true },
    fields: [
        { name: "server", type: "string", tab: "basic", required: true,
          validate: "host", ui_label: "Server", json_key: "server", omit_when: "never" },
        { name: "server_port", type: "number", tab: "basic", required: true,
          validate: "port", default: 443, ui_label: "Server port",
          json_key: "server_port", coerce: "num", omit_when: "never" },
        { name: "shadowtls_version", type: "enum", tab: "basic", values: ["3", "2", "1"],
          default: "3", ui_label: "Version", json_key: "version", coerce: "num" },
        { name: "server_password", type: "string", tab: "basic", secret: true,
          ui_label: "Password", json_key: "password" },
    ],
});

reg.register({
    kind: "inbound", type: "shadowtls", sing_box_type: "shadowtls",
    fields: [
        { name: "listen", type: "string", tab: "basic", default: "::", ui_label: "Listen address" },
        { name: "listen_port", type: "number", tab: "basic", required: true,
          validate: "port", default: 443, ui_label: "Listen port" },
        { name: "shadowtls_version", type: "enum", tab: "basic", values: ["3", "2", "1"],
          default: "3", ui_label: "Version", json_key: "version", coerce: "num" },
        { name: "server_password", type: "string", tab: "basic", secret: true,
          ui_label: "Password (v1/v2)", json_key: "password" },
        { name: "shadowtls_user", type: "list", tab: "basic", secret: true,
          ui_label: "Users (name:password) (v3)", placeholder: "alice:secret" },
        { name: "handshake_server", type: "string", tab: "basic", required: true,
          ui_label: "Handshake server", placeholder: "google.com" },
        { name: "handshake_server_port", type: "number", tab: "basic",
          ui_label: "Handshake server port", default: 443 },
        { name: "strict_mode", type: "bool", tab: "basic", ui_label: "Strict mode",
          advanced: true, json_key: "strict_mode", coerce: "bool" },
        { name: "wildcard_sni", type: "string", tab: "basic", ui_label: "Wildcard SNI (1.12+)",
          advanced: true, json_key: "wildcard_sni", min_version: "1.12" },
    ],
    groups: [
        { json_key: "handshake", gate: { any_present: ["handshake_server", "handshake_server_port"] },
          fields: [
              { name: "handshake_server",      json_key: "server" },
              { name: "handshake_server_port", json_key: "server_port", coerce: "num" },
          ] },
    ],
    users: {
        from: "shadowtls_user",
        columns: [ { key: "name", required: true }, { key: "password", always: true } ],
    },
});

return {};
