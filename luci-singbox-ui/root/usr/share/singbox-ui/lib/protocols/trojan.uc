// lib/protocols/trojan.uc — Trojan outbound + inbound under the E2 DSL.

let reg = require("protocols.registry");
let tls_blk = require("protocols._shared.tls");
let tr_blk  = require("protocols._shared.transport");
let mux_blk = require("protocols._shared.multiplex");
let dial_blk = require("protocols._shared.dial");

// Outbound is fully declarative (protocols._filler); the shared-block requires
// above remain for the inbound emit() below. s_opt/s_num/helpers were dropped
// with the outbound emit() — they are no longer referenced.

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

    emit: function(s) {
        let inb = require("inbound");
        let out = dial_blk.build_listen_base(s, "trojan");
        if (!out) return null;
        out.users = [ inb.build_user(s) ];
        let t = tls_blk.emit_inbound(s);  if (t) out.tls = t;
        let r = tr_blk.emit(s);           if (r) out.transport = r;
        let m = mux_blk.emit(s);          if (m) out.multiplex = m;
        return out;
    },
});

return {};
