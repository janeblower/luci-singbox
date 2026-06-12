// lib/protocols/_shared/dial.uc

let helpers = require("helpers");
const s_opt  = helpers.s_opt;
const s_bool = helpers.s_bool;
const s_num  = helpers.s_num;

function emit_outbound(s) {
    let out = {};
    // Caller must resolve UCI logical iface names (e.g. "wan") to netdev names
    // before passing — see helpers.resolve_iface_device in outbound.uc.
    if (length(s_opt(s, "bind_interface")))
        out.bind_interface = s.bind_interface;
    if (length(s_opt(s, "inet4_bind_address")))
        out.inet4_bind_address = s.inet4_bind_address;
    if (length(s_opt(s, "inet6_bind_address")))
        out.inet6_bind_address = s.inet6_bind_address;
    if (length(s_opt(s, "routing_mark")))
        out.routing_mark = s_num(s.routing_mark);
    if (s_bool(s, "reuse_addr"))
        out.reuse_addr = true;
    if (length(s_opt(s, "connect_timeout")))
        out.connect_timeout = s.connect_timeout;
    if (s_bool(s, "tcp_fast_open"))
        out.tcp_fast_open = true;
    if (s_bool(s, "tcp_multi_path"))
        out.tcp_multi_path = true;
    if (s_bool(s, "udp_fragment"))
        out.udp_fragment = true;
    if (length(s_opt(s, "domain_strategy")))
        out.domain_strategy = s.domain_strategy;
    if (length(s_opt(s, "network_strategy")))
        out.network_strategy = s.network_strategy;
    if (length(s_opt(s, "fallback_delay")))
        out.fallback_delay = s.fallback_delay;
    if (length(s_opt(s, "detour")))
        out.detour = s.detour;
    if (length(s_opt(s, "netns")))
        out.netns = s.netns;
    return out;
}

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

// merge_dial(out, s) — fold the shared dial fields into an outbound object.
// Replaces the `let d = emit_outbound(s); for (k in keys(d)) out[k]=d[k];`
// boilerplate repeated across outbound emitters. (S4-QUAL)
function merge_dial(out, s) {
    let d = emit_outbound(s);
    for (let k in keys(d)) out[k] = d[k];
    return out;
}

return {
    applies_to: { kinds: [ "outbound" ] },

    fields: [
        { name: "bind_interface", type: "string", tab: "dial",
          ui_label: "Bind interface", placeholder: "wan",
          dynamic: "interfaces" },

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

    emit_outbound: emit_outbound,
    build_listen_base: build_listen_base,
    merge_dial: merge_dial,

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
