// lib/protocols/_shared/dial.uc

let helpers = require("helpers");
const s_opt  = helpers.s_opt;
const s_num  = helpers.s_num;

// build_listen_base(s, type_) — common inbound prelude. Validates listen_port
// (warns + returns null if missing, matching every inbound emitter's guard),
// and returns the base { type, tag, listen, listen_port } object with the
// "::" listen default applied. Callers extend the returned object. (S4-QUAL)
function build_listen_base(s, type_) {
    let port = s_num(s.listen_port);
    if (!port) {
        warn(sprintf("%s inbound: missing listen_port for '%s'\n", type_, s[".name"]));
        return null;
    }
    return {
        type: type_,
        tag: s[".name"],
        listen: length(s_opt(s, "listen")) ? s.listen : "::",
        listen_port: port,
    };
}

return {
    applies_to: { kinds: [ "outbound", "dns" ] },

    fields: [
        // sing-box hands this straight to SO_BINDTODEVICE, so it is an OS netdev
        // name (eth0 / br-lan / pppoe-wan), NOT an OpenWrt logical interface. The
        // dropdown used to be filled from uci network.interface (wan/lan), which
        // meant every value it offered bound the dialer to a device that does not
        // exist — the outbound then failed to connect, silently. `devices` lists
        // real netdevs; free entry stays possible (eth0.100 and friends aren't
        // enumerable).
        { name: "bind_interface", type: "string", tab: "dial",
          ui_label: "Bind interface (netdev)", placeholder: "eth0",
          ui_help: "OS network device, e.g. eth0 or pppoe-wan — not the OpenWrt interface name (wan/lan). Leave empty to follow the system routing table.",
          dynamic: "devices" },

        { name: "inet4_bind_address", type: "string", tab: "dial",
          ui_label: "IPv4 bind address", placeholder: "0.0.0.0", advanced: true },
        { name: "inet6_bind_address", type: "string", tab: "dial",
          ui_label: "IPv6 bind address", placeholder: "::", advanced: true },
        { name: "routing_mark", type: "number", tab: "dial",
          ui_label: "Routing mark (fwmark)", advanced: true },
        { name: "reuse_addr", type: "bool", tab: "dial",
          ui_label: "SO_REUSEADDR", default: 0, advanced: true },
        { name: "connect_timeout", type: "string", tab: "dial",
          ui_label: "Connect timeout", placeholder: "5s", advanced: true },
        { name: "tcp_fast_open", type: "bool", tab: "dial",
          ui_label: "TCP fast open", default: 0, advanced: true },
        { name: "tcp_multi_path", type: "bool", tab: "dial",
          ui_label: "TCP MPTCP", default: 0, advanced: true },
        { name: "udp_fragment", type: "bool", tab: "dial",
          ui_label: "UDP fragment", default: 0, advanced: true },
        { name: "domain_strategy", type: "enum", tab: "dial",
          ui_label: "Domain strategy (deprecated 1.12)",
          values: ["", "prefer_ipv4", "prefer_ipv6", "ipv4_only", "ipv6_only"],
          advanced: true },
        { name: "network_strategy", type: "enum", tab: "dial",
          ui_label: "Network strategy",
          values: ["", "default", "fallback", "hybrid"],
          advanced: true },
        { name: "fallback_delay", type: "string", tab: "dial",
          ui_label: "Fallback delay", placeholder: "300ms", advanced: true },
        { name: "detour", type: "string", tab: "dial",
          ui_label: "Detour outbound tag", placeholder: "another_outbound",
          dynamic: "outbounds", advanced: true },
        { name: "netns", type: "string", tab: "dial",
          ui_label: "Network namespace", placeholder: "/var/run/netns/xx", advanced: true },
    ],

    build_listen_base: build_listen_base,

    emit_spec: {
        merge: true,
        seq: [
            { name: "bind_interface",     json_key: "bind_interface" },
            { name: "inet4_bind_address", json_key: "inet4_bind_address" },
            { name: "inet6_bind_address", json_key: "inet6_bind_address" },
            { name: "routing_mark",       json_key: "routing_mark", coerce: "num" },
            { name: "reuse_addr",         json_key: "reuse_addr", coerce: "bool" },
            { name: "connect_timeout",    json_key: "connect_timeout" },
            { name: "tcp_fast_open",      json_key: "tcp_fast_open", coerce: "bool" },
            { name: "tcp_multi_path",     json_key: "tcp_multi_path", coerce: "bool" },
            { name: "udp_fragment",       json_key: "udp_fragment", coerce: "bool" },
            { name: "domain_strategy",    json_key: "domain_strategy" },
            { name: "network_strategy",   json_key: "network_strategy" },
            { name: "fallback_delay",     json_key: "fallback_delay" },
            { name: "detour",             json_key: "detour" },
            { name: "netns",              json_key: "netns" },
        ],
    },
};
