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
        let out = dial_blk.build_listen_base(s, "shadowsocks");
        if (!out) return null;
        out.method = s_opt(s, "shadowsocks_method");
        out.password = s_opt(s, "server_password");
        if (length(s_opt(s, "network"))) out.network = s.network;
        let users = [];
        for (let u in as_array(s.ss_user)) {
            let c1 = index(u, ":");
            if (c1 < 0) continue;
            let rest = substr(u, c1 + 1);
            let c2 = index(rest, ":");
            if (c2 < 0) continue;          // require name:method:password shape
            let nm = substr(u, 0, c1);
            let mth = substr(rest, 0, c2);
            let pw = substr(rest, c2 + 1);
            if (!length(nm)) continue;
            // S2.2: a sing-box shadowsocks inbound user has NO per-user `method`
            // — the cipher is a single inbound-root property shared by all users
            // (out.method above). Emitting a per-user method is an unknown field
            // that sing-box rejects on strict parse, so the inbound never starts.
            // The middle token is still parsed (kept in the UI format for
            // back-compat) but discarded rather than emitted.
            // 1.6: the discarded middle token must still name a real cipher, and
            // the password must be non-empty — otherwise the whole inbound is
            // rejected loudly at sing-box load. Warn+skip the bad entry instead.
            if (!(mth in METHODS)) {
                warn(sprintf("shadowsocks.uc: ss_user '%s' has unknown method '%s'; skipping\n", nm, mth));
                continue;
            }
            if (!length(pw)) {
                warn(sprintf("shadowsocks.uc: ss_user '%s' has empty password; skipping\n", nm));
                continue;
            }
            push(users, { name: nm, password: pw });
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
