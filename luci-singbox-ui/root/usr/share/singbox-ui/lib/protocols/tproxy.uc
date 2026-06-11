// lib/protocols/tproxy.uc — TProxy inbound under the E2 DSL.

let reg     = require("protocols.registry");
let helpers = require("helpers");
let dial_blk = require("protocols._shared.dial");

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
          values: ["", "tcp", "udp"], default: "",
          ui_label: "Network" },
        { name: "tcp_fast_open", type: "bool", tab: "basic",
          ui_label: "TCP fast open", default: 0, advanced: true },
        { name: "udp_fragment", type: "bool", tab: "basic",
          ui_label: "UDP fragment", default: 0, advanced: true },
        // Persisted to UCI and consumed by nftables.uc — NOT emitted to
        // sing-box JSON (emit() below simply omits them). These must NOT be
        // `virtual`: descriptor_form.makeVirtual() write-suppresses virtual
        // fields, which silently discarded every modal edit to them. The
        // interface set holds netdev DEVICE names (br-lan, eth0, eth0.100)
        // because nftables matches them via `iifname @wan_ifaces`.
        { name: "interface", type: "list", tab: "basic",
          ui_label: "Interfaces to redirect (nftables)", dynamic: "devices" },
        { name: "nft_rules", type: "bool", tab: "basic",
          ui_label: "Install nftables redirect rules", default: 1 },
        { name: "hijack_dns", type: "bool", tab: "basic",
          ui_label: "Hijack DNS via nftables", default: 0 },
    ],

    emit: function(s) {
        let out = dial_blk.build_listen_base(s, "tproxy");
        if (!out) return null;
        let net = s_opt(s, "network");
        if (net == "tcp" || net == "udp") out.network = net;
        if (s_bool(s, "tcp_fast_open")) out.tcp_fast_open = true;
        if (s_bool(s, "udp_fragment"))  out.udp_fragment  = true;
        return out;
    },
});

return {};
