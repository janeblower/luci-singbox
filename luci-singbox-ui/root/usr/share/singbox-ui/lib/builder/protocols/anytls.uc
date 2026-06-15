// lib/builder/protocols/anytls.uc — AnyTLS outbound + inbound (Since sing-box 1.12.0).
let reg = require("builder.protocols.registry");

reg.register({
    kind: "outbound", type: "anytls", sing_box_type: "anytls",
    min_version: "1.12",
    shared: { tls: { force_enabled: true }, dial: true },
    fields: [
        { name: "server", type: "string", tab: "basic", required: true,
          validate: "host", ui_label: "Server", json_key: "server", omit_when: "never" },
        { name: "server_port", type: "number", tab: "basic", required: true,
          validate: "port", default: 443, ui_label: "Server port",
          json_key: "server_port", coerce: "num", omit_when: "never" },
        { name: "server_password", type: "string", tab: "basic", required: true, secret: true,
          ui_label: "Password", json_key: "password", omit_when: "never" },
        { name: "idle_session_check_interval", type: "string", tab: "basic",
          ui_label: "Idle session check interval", placeholder: "30s", advanced: true,
          json_key: "idle_session_check_interval" },
        { name: "idle_session_timeout", type: "string", tab: "basic",
          ui_label: "Idle session timeout", placeholder: "30s", advanced: true,
          json_key: "idle_session_timeout" },
        { name: "min_idle_session", type: "number", tab: "basic",
          ui_label: "Min idle sessions", advanced: true,
          json_key: "min_idle_session", coerce: "num" },
    ],
});

reg.register({
    kind: "inbound", type: "anytls", sing_box_type: "anytls",
    min_version: "1.12",
    shared: { tls: { force_enabled: true } },
    fields: [
        { name: "listen", type: "string", tab: "basic", default: "::", ui_label: "Listen address" },
        { name: "listen_port", type: "number", tab: "basic", required: true,
          validate: "port", default: 443, ui_label: "Listen port" },
        { name: "anytls_user", type: "list", tab: "basic", secret: true,
          ui_label: "Users (name:password)", placeholder: "alice:secret" },
        { name: "padding_scheme", type: "list", tab: "basic", ui_label: "Padding scheme",
          advanced: true, json_key: "padding_scheme", coerce: "array" },
    ],
    users: {
        from: "anytls_user",
        columns: [ { key: "name", required: true }, { key: "password", tail: true, always: true } ],
    },
});

return {};
