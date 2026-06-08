// lib/protocols/tproxy.uc — TProxy inbound under the E2 DSL.

let reg     = require("protocols.registry");
let helpers = require("helpers");

const s_opt  = helpers.s_opt;
const s_num  = helpers.s_num;
const s_bool = helpers.s_bool;

reg.register({
    kind: "inbound", type: "tproxy", sing_box_type: "tproxy",

    fields: [
        { name: "listen", type: "string", tab: "basic", default: "::",
          ui_label: "Listen address" },
        { name: "listen_port", type: "number", tab: "basic", required: true,
          validate: "port", default: 7895, ui_label: "Listen port" },
        { name: "network", type: "enum", tab: "basic",
          options: ["", "tcp", "udp"], default: "",
          ui_label: "Network" },
        { name: "tcp_fast_open", type: "bool", tab: "basic",
          ui_label: "TCP fast open", default: 0, advanced: true },
        { name: "udp_fragment", type: "bool", tab: "basic",
          ui_label: "UDP fragment", default: 0, advanced: true },
        // UI-only — not emitted to sing-box JSON; consumed by nftables.uc + UI.
        { name: "interface", type: "list", tab: "basic",
          ui_label: "Interfaces to redirect (nftables)", virtual: true },
        { name: "nft_rules", type: "bool", tab: "basic",
          ui_label: "Install nftables redirect rules", default: 1, virtual: true },
        { name: "hijack_dns", type: "bool", tab: "basic",
          ui_label: "Hijack DNS via nftables", default: 0, virtual: true },
    ],

    emit: function(s) {
        let port = s_num(s.listen_port);
        if (!port) {
            warn(sprintf("tproxy inbound: missing listen_port for '%s'\n", s[".name"]));
            return null;
        }
        let out = {
            type:         "tproxy",
            tag:          s[".name"],
            listen:       length(s_opt(s, "listen")) ? s.listen : "::",
            listen_port:  port,
        };
        if (length(s_opt(s, "network"))) out.network = s.network;
        if (s_bool(s, "tcp_fast_open")) out.tcp_fast_open = true;
        if (s_bool(s, "udp_fragment"))  out.udp_fragment  = true;
        return out;
    },
});

return {};
