// lib/protocols/hysteria2.uc — Hysteria2 outbound + inbound (E2 DSL).
// TLS is mandatory for hysteria2; the shared TLS block is invoked with
// force_enabled so the JSON always carries a tls{} block.

let reg = require("protocols.registry");
let helpers = require("helpers");
let tls_blk = require("protocols._shared.tls");
let dial_blk = require("protocols._shared.dial");

const s_opt = helpers.s_opt;
const s_num = helpers.s_num;
const s_bool = helpers.s_bool;
const as_array = helpers.as_array;

reg.register({
    kind: "outbound", type: "hysteria2", sing_box_type: "hysteria2",
    shared: { tls: { force_enabled: true }, dial: true },

    fields: [
        { name: "server", type: "string", tab: "basic", required: true,
          validate: "host", ui_label: "Server" },
        { name: "server_port", type: "number", tab: "basic", required: true,
          validate: "port", default: 443, ui_label: "Server port" },
        { name: "server_password", type: "string", tab: "basic", required: true,
          secret: true, ui_label: "Password" },
        { name: "up_mbps", type: "number", tab: "basic",
          ui_label: "Uplink Mbps", placeholder: "50" },
        { name: "down_mbps", type: "number", tab: "basic",
          ui_label: "Downlink Mbps", placeholder: "200" },
        { name: "obfs_type", type: "enum", tab: "basic",
          values: ["", "salamander"], ui_label: "Obfs type", advanced: true },
        { name: "obfs_password", type: "string", tab: "basic",
          secret: true, ui_label: "Obfs password", advanced: true,
          parent_enabled: "obfs_type" },
        { name: "network", type: "enum", tab: "basic",
          values: ["", "tcp", "udp"], ui_label: "Network", advanced: true },
        { name: "brutal_debug", type: "bool", tab: "basic",
          ui_label: "Brutal debug", default: 0, advanced: true },
        { name: "masquerade", type: "string", tab: "basic",
          ui_label: "Masquerade URL", placeholder: "https://example.com",
          advanced: true },
    ],

    emit: function(s) {
        let out = {
            type: "hysteria2",
            tag: s[".name"],
            server: s_opt(s, "server"),
            server_port: s_num(s.server_port),
            password: s_opt(s, "server_password"),
        };
        if (length(s_opt(s, "obfs_type")) && length(s_opt(s, "obfs_password"))) {
            out.obfs = {
                type: s.obfs_type,
                password: s.obfs_password,
            };
        }
        if (length(s_opt(s, "up_mbps")))   out.up_mbps   = s_num(s.up_mbps);
        if (length(s_opt(s, "down_mbps"))) out.down_mbps = s_num(s.down_mbps);
        if (length(s_opt(s, "masquerade"))) out.masquerade = s.masquerade;
        if (s_bool(s, "brutal_debug")) out.brutal_debug = true;
        let net = s_opt(s, "network");
        if (net === "tcp" || net === "udp") out.network = net;
        let t = tls_blk.emit_outbound(s, { force_enabled: true });
        if (t) out.tls = t;
        let d = dial_blk.emit_outbound(s);
        for (let k in keys(d)) out[k] = d[k];
        return out;
    },
});

reg.register({
    kind: "inbound", type: "hysteria2", sing_box_type: "hysteria2",
    shared: { tls: { force_enabled: true } },

    fields: [
        { name: "listen", type: "string", tab: "basic", default: "::",
          ui_label: "Listen address" },
        { name: "listen_port", type: "number", tab: "basic", required: true,
          validate: "port", default: 443, ui_label: "Listen port" },
        // ui_label is plain "Password" rather than "Password (single user)":
        // applyMaterialized() in descriptor_form.js dedupes shared (tab,name)
        // pairs across protocols and keeps the FIRST registered label. Both
        // shadowsocks and trojan also register (basic, server_password) with
        // ui_label "Password" and run earlier in SB_INBOUND_PROTOCOLS, so any
        // parenthetical here is silently dropped. The multi-user fallback is
        // expressed by the adjacent inbound_user list ("Users (name:password)").
        { name: "server_password", type: "string", tab: "basic", required: true,
          secret: true, ui_label: "Password" },
        { name: "inbound_user", type: "list", tab: "basic", secret: true,
          ui_label: "Users (name:password)", advanced: true },
        { name: "up_mbps", type: "number", tab: "basic",
          ui_label: "Uplink Mbps" },
        { name: "down_mbps", type: "number", tab: "basic",
          ui_label: "Downlink Mbps" },
        { name: "ignore_client_bandwidth", type: "bool", tab: "basic",
          ui_label: "Ignore client bandwidth", default: 0, advanced: true },
        { name: "obfs_type", type: "enum", tab: "basic",
          values: ["", "salamander"], ui_label: "Obfs type", advanced: true },
        { name: "obfs_password", type: "string", tab: "basic",
          secret: true, ui_label: "Obfs password", advanced: true,
          parent_enabled: "obfs_type" },
        { name: "masquerade", type: "string", tab: "basic",
          ui_label: "Masquerade URL", placeholder: "https://example.com",
          advanced: true },
        { name: "brutal_debug", type: "bool", tab: "basic",
          ui_label: "Brutal debug", default: 0, advanced: true },
    ],

    emit: function(s) {
        let port = s_num(s.listen_port);
        if (!port) {
            warn(sprintf("hysteria2 inbound: missing listen_port for '%s'\n", s[".name"]));
            return null;
        }
        let out = {
            type: "hysteria2",
            tag: s[".name"],
            listen: length(s_opt(s, "listen")) ? s.listen : "::",
            listen_port: port,
        };
        let users = [];
        for (let u in as_array(s.inbound_user)) {
            let parts = split(u, ":");
            if (length(parts) >= 2)
                push(users, { name: parts[0], password: parts[1] });
        }
        if (length(users)) {
            out.users = users;
        } else if (length(s_opt(s, "server_password"))) {
            out.users = [ { name: s[".name"], password: s.server_password } ];
        }
        if (length(s_opt(s, "obfs_type")) && length(s_opt(s, "obfs_password")))
            out.obfs = { type: s.obfs_type, password: s.obfs_password };
        if (length(s_opt(s, "up_mbps")))   out.up_mbps   = s_num(s.up_mbps);
        if (length(s_opt(s, "down_mbps"))) out.down_mbps = s_num(s.down_mbps);
        if (length(s_opt(s, "masquerade")))
            out.masquerade = s.masquerade;
        if (s_bool(s, "brutal_debug")) out.brutal_debug = true;
        if (s_bool(s, "ignore_client_bandwidth"))
            out.ignore_client_bandwidth = true;
        let t = tls_blk.emit_inbound(s, { force_enabled: true });
        if (t) out.tls = t;
        return out;
    },
});

return {};
