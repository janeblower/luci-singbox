// lib/protocols/trojan.uc — Trojan outbound + inbound under the E2 DSL.

let reg = require("protocols.registry");
let helpers = require("helpers");
let tls_blk = require("protocols._shared.tls");
let tr_blk  = require("protocols._shared.transport");
let mux_blk = require("protocols._shared.multiplex");
let dial_blk = require("protocols._shared.dial");

const s_opt = helpers.s_opt;
const s_num = helpers.s_num;

// --- Outbound ------------------------------------------------------------

reg.register({
    kind: "outbound", type: "trojan", sing_box_type: "trojan",
    shared: { tls: {}, transport: {}, multiplex: {}, dial: true },

    fields: [
        { name: "server", type: "string", tab: "basic", required: true,
          validate: "host", ui_label: "Server" },
        { name: "server_port", type: "number", tab: "basic", required: true,
          validate: "port", ui_label: "Server port", default: 443 },
        { name: "server_password", type: "string", tab: "basic", required: true,
          secret: true, ui_label: "Password" },
    ],

    emit: function(s) {
        let out = {
            type: "trojan",
            tag:  s[".name"],
            server:      s_opt(s, "server"),
            server_port: s_num(s.server_port),
        };
        if (length(s_opt(s, "server_password"))) out.password = s.server_password;
        let t = tls_blk.emit_outbound(s);  if (t) out.tls = t;
        let r = tr_blk.emit(s);            if (r) out.transport = r;
        let m = mux_blk.emit(s);           if (m) out.multiplex = m;
        let d = dial_blk.emit_outbound(s);
        for (let k in keys(d)) out[k] = d[k];
        return out;
    },
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

    emit: function(s) {
        let inb = require("inbound");
        let port = s_num(s.listen_port);
        if (!port) {
            warn(sprintf("trojan inbound: missing listen_port for '%s'\n", s[".name"]));
            return null;
        }
        let out = {
            type: "trojan",
            tag: s[".name"],
            listen: length(s_opt(s, "listen")) ? s.listen : "::",
            listen_port: port,
            users: [ inb.build_user(s) ],
        };
        let t = tls_blk.emit_inbound(s);  if (t) out.tls = t;
        let r = tr_blk.emit(s);           if (r) out.transport = r;
        let m = mux_blk.emit(s);          if (m) out.multiplex = m;
        return out;
    },
});

return {};
