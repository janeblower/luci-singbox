// lib/protocols/shadowsocks.uc — Shadowsocks outbound + inbound (E2 DSL).

let reg = require("protocols.registry");
let helpers = require("helpers");
let mux_blk = require("protocols._shared.multiplex");
let dial_blk = require("protocols._shared.dial");

const s_opt = helpers.s_opt;
const s_num = helpers.s_num;
const as_array = helpers.as_array;

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
          validate: "host", ui_label: "Server" },
        { name: "server_port", type: "number", tab: "basic", required: true,
          validate: "port", ui_label: "Server port" },
        { name: "shadowsocks_method", type: "enum", tab: "basic", required: true,
          values: METHODS, default: "2022-blake3-aes-128-gcm",
          ui_label: "Method" },
        { name: "server_password", type: "string", tab: "basic", required: true,
          secret: true, ui_label: "Password" },
        { name: "plugin", type: "string", tab: "basic",
          ui_label: "Plugin", advanced: true },
        { name: "plugin_opts", type: "string", tab: "basic",
          ui_label: "Plugin opts", advanced: true },
        { name: "network", type: "enum", tab: "basic",
          values: ["", "tcp", "udp"], ui_label: "Network", advanced: true },
        { name: "udp_over_tcp", type: "bool", tab: "basic",
          ui_label: "UDP over TCP", advanced: true },
    ],

    emit: function(s) {
        let out = {
            type: "shadowsocks",
            tag: s[".name"],
            server: s_opt(s, "server"),
            server_port: s_num(s.server_port),
            method: s_opt(s, "shadowsocks_method"),
            password: s_opt(s, "server_password"),
        };
        if (length(s_opt(s, "network"))) out.network = s.network;
        if (length(s_opt(s, "plugin"))) {
            out.plugin = s.plugin;
            if (length(s_opt(s, "plugin_opts"))) out.plugin_opts = s.plugin_opts;
        }
        if (helpers.s_bool(s, "udp_over_tcp")) out.udp_over_tcp = true;
        let m = mux_blk.emit(s); if (m) out.multiplex = m;
        let d = dial_blk.emit_outbound(s);
        for (let k in keys(d)) out[k] = d[k];
        return out;
    },
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
          values: METHODS, default: "2022-blake3-aes-128-gcm",
          ui_label: "Method" },
        { name: "server_password", type: "string", tab: "basic", required: true,
          secret: true, ui_label: "Password" },
        { name: "ss_user", type: "list", tab: "basic", secret: true,
          ui_label: "Users (name:method:password)",
          placeholder: "alice:2022-blake3-aes-128-gcm:base64==",
          advanced: true },
        { name: "network", type: "enum", tab: "basic",
          values: ["", "tcp", "udp"], ui_label: "Network", advanced: true },
    ],

    emit: function(s) {
        let port = s_num(s.listen_port);
        if (!port) {
            warn(sprintf("ss inbound: missing listen_port for '%s'\n", s[".name"]));
            return null;
        }
        let out = {
            type: "shadowsocks",
            tag: s[".name"],
            listen: length(s_opt(s, "listen")) ? s.listen : "::",
            listen_port: port,
            method: s_opt(s, "shadowsocks_method"),
            password: s_opt(s, "server_password"),
        };
        if (length(s_opt(s, "network"))) out.network = s.network;
        let users = [];
        for (let u in as_array(s.ss_user)) {
            let parts = split(u, ":");
            if (length(parts) >= 3)
                push(users, { name: parts[0], method: parts[1], password: parts[2] });
        }
        if (length(users)) {
            out.users = users;
            delete out.password;
        }
        let m = mux_blk.emit(s); if (m) out.multiplex = m;
        return out;
    },
});

return {};
