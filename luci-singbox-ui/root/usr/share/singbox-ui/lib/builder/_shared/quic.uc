// lib/builder/_shared/quic.uc — QUIC Fields shared block (Since sing-box 1.14.0).
// Merged flat into the root object (like dial). Used by hysteria/hysteria2/tuic.

return {
    applies_to: { kinds: [ "inbound", "outbound" ] },

    fields: [
        { name: "quic_initial_packet_size", type: "number", tab: "basic",
          ui_label: "Initial packet size (1.14+)", advanced: true, min_version: "1.14" },
        { name: "quic_disable_path_mtu_discovery", type: "bool", tab: "basic",
          ui_label: "Disable path MTU discovery (1.14+)", default: 0, advanced: true,
          min_version: "1.14" },
    ],

    emit_spec: {
        merge: true,
        seq: [
            { name: "quic_initial_packet_size",        json_key: "initial_packet_size", coerce: "num" },
            { name: "quic_disable_path_mtu_discovery", json_key: "disable_path_mtu_discovery", coerce: "bool" },
        ],
    },
};
