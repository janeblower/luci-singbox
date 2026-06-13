// lib/protocols/tproxy.uc — TProxy inbound under the E2 DSL.

let reg = require("builder.protocols.registry");

reg.register({
    kind: "inbound", type: "tproxy", sing_box_type: "tproxy",

    fields: [
        { name: "listen", type: "string", tab: "basic", default: "::",
          ui_label: "Listen address" },
        { name: "listen_port", type: "number", tab: "basic", required: true,
          validate: "port", default: 7895, ui_label: "Listen port" },
        { name: "network", type: "enum", tab: "basic",
          values: ["", "tcp", "udp"], default: "",
          ui_label: "Network", json_key: "network", only_values: ["tcp", "udp"] },
        { name: "tcp_fast_open", type: "bool", tab: "basic",
          ui_label: "TCP fast open", default: 0, advanced: true,
          json_key: "tcp_fast_open", coerce: "bool" },
        { name: "udp_fragment", type: "bool", tab: "basic",
          ui_label: "UDP fragment", default: 0, advanced: true,
          json_key: "udp_fragment", coerce: "bool" },
        // UI-only (no json_key) — persisted to UCI, consumed by nftables.uc,
        // NOT emitted to sing-box JSON. Must NOT be `virtual`:
        // descriptor_form.makeVirtual() write-suppresses virtual fields, which
        // silently discarded every modal edit. The interface set holds netdev
        // DEVICE names (br-lan, eth0, eth0.100) — nftables matches via iifname.
        { name: "interface", type: "list", tab: "basic",
          ui_label: "Interfaces to redirect (nftables)", dynamic: "devices" },
        { name: "nft_rules", type: "bool", tab: "basic",
          ui_label: "Install nftables redirect rules", default: 1 },
        { name: "hijack_dns", type: "bool", tab: "basic",
          ui_label: "Hijack DNS via nftables", default: 0 },
    ],
});

return {};
