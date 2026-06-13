// lib/protocols/trojan.uc — Trojan outbound + inbound under the E2 DSL.

let reg = require("protocols.registry");

// --- Outbound ------------------------------------------------------------

reg.register({
    kind: "outbound", type: "trojan", sing_box_type: "trojan",
    shared: { tls: {}, transport: {}, multiplex: {}, dial: true },

    fields: [
        { name: "server", type: "string", tab: "basic", required: true,
          validate: "host", ui_label: "Server",
          json_key: "server", omit_when: "never" },
        { name: "server_port", type: "number", tab: "basic", required: true,
          validate: "port", ui_label: "Server port", default: 443,
          json_key: "server_port", coerce: "num", omit_when: "never" },
        { name: "server_password", type: "string", tab: "basic", required: true,
          secret: true, ui_label: "Password",
          json_key: "password" },
    ],
    // No emit(): protocols._filler builds {type,tag} + the three fields above +
    // the declared tls/transport/multiplex/dial shared blocks, byte-identical to
    // the former hand-written emit().
});

// --- Inbound -------------------------------------------------------------

reg.register({
    kind: "inbound", type: "trojan", sing_box_type: "trojan",
    shared: { tls: {}, transport: {}, multiplex: {} },

    fields: [
        { name: "listen", type: "string", tab: "basic", default: "::",
          ui_label: "Listen address" },
        { name: "listen_port", type: "number", tab: "basic", required: true,
          validate: "port", ui_label: "Listen port" },
        { name: "server_password", type: "string", tab: "basic", required: true,
          secret: true, ui_label: "Password" },
    ],

    users: {
        single_fallback: { fields: [ { key: "password", from: "server_password" } ] },
    },
});

return {};
