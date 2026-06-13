// lib/builder/protocols/http.uc — HTTP CONNECT proxy outbound + inbound (E2 DSL).
let reg = require("builder.protocols.registry");

reg.register({
    kind: "outbound", type: "http", sing_box_type: "http",
    shared: { tls: {}, dial: true },
    fields: [
        { name: "server", type: "string", tab: "basic", required: true,
          validate: "host", ui_label: "Server", json_key: "server", omit_when: "never" },
        { name: "server_port", type: "number", tab: "basic", required: true,
          validate: "port", default: 8080, ui_label: "Server port",
          json_key: "server_port", coerce: "num", omit_when: "never" },
        { name: "username", type: "string", tab: "basic", ui_label: "Username", json_key: "username" },
        { name: "password", type: "string", tab: "basic", secret: true, ui_label: "Password", json_key: "password" },
        { name: "http_path", type: "string", tab: "basic", ui_label: "Path", advanced: true,
          placeholder: "/", json_key: "path" },
    ],
});

reg.register({
    kind: "inbound", type: "http", sing_box_type: "http",
    shared: { tls: {} },
    fields: [
        { name: "listen", type: "string", tab: "basic", default: "::", ui_label: "Listen address" },
        { name: "listen_port", type: "number", tab: "basic", required: true,
          validate: "port", default: 8080, ui_label: "Listen port" },
        { name: "http_user", type: "list", tab: "basic", secret: true,
          ui_label: "Users (username:password)", placeholder: "alice:secret" },
    ],
    users: {
        from: "http_user",
        columns: [ { key: "username", required: true }, { key: "password", tail: true, always: true } ],
    },
});

return {};
