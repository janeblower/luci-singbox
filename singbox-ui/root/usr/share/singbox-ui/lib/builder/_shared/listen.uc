// lib/builder/_shared/listen.uc — sing-box "Listen Fields" (shared).
// https://sing-box.sagernet.org/configuration/shared/listen/
//
// Applies to LISTENER inbounds only. `tun` is NOT one of them: the doc page for
// tun renders a "Listen Fields" section, but that is a doc-generator artifact —
// sing-box 1.13.13 rejects every one of these keys on a tun inbound with
// `json: unknown field "..."` and refuses the whole config. The only listen-ish
// key tun accepts is `udp_timeout`, which tun.uc declares itself.
// `cloudflared` opts out too (it has no listen fields at all).
//
// The deprecated 1.11 set (sniff / sniff_override_destination / sniff_timeout /
// domain_strategy / udp_disable_domain_unmapping) is intentionally NOT emitted:
// since 1.11 those are route actions, not inbound fields.
//
// `listen` and `listen_port` deliberately stay in the individual descriptors.
// They look like the most shared fields of all, but the default port is part of
// each protocol's identity — 443 for the TLS-ish ones, 1080 for socks/mixed,
// 8080 for http, 7895 for tproxy, 7894 for redirect — and a shared block carries
// exactly one `default`. Hoisting them would silently strip the port prefill from
// 13 descriptors. This block owns the options AROUND the listener, not the
// listener's own address.

return {
    applies_to: { kinds: [ "inbound" ] },

    fields: [
        { name: "tcp_fast_open", type: "bool", tab: "basic", default: 0,
          ui_label: "TCP fast open", advanced: true },
        { name: "tcp_multi_path", type: "bool", tab: "basic", default: 0,
          ui_label: "TCP MPTCP", advanced: true },
        { name: "udp_fragment", type: "bool", tab: "basic", default: 0,
          ui_label: "UDP fragment", advanced: true },
        { name: "udp_timeout", type: "string", tab: "basic",
          ui_label: "UDP NAT timeout", placeholder: "5m", advanced: true },
        { name: "detour", type: "string", tab: "basic",
          ui_label: "Detour to inbound", placeholder: "another_inbound",
          ui_help: "Forward accepted connections to another inbound. The target inbound must be injectable.",
          advanced: true },

        // sing-box hands bind_interface to SO_BINDTODEVICE: an OS netdev
        // (eth0 / br-lan / pppoe-wan), NOT an OpenWrt logical interface.
        { name: "bind_interface", type: "string", tab: "basic",
          ui_label: "Bind interface (netdev)", placeholder: "eth0",
          ui_help: "OS network device, e.g. eth0 or pppoe-wan — not the OpenWrt interface name (wan/lan).",
          dynamic: "devices", advanced: true, min_version: "1.12" },
        { name: "routing_mark", type: "number", tab: "basic",
          ui_label: "Routing mark (fwmark)", advanced: true, min_version: "1.12" },
        { name: "reuse_addr", type: "bool", tab: "basic", default: 0,
          ui_label: "SO_REUSEADDR", advanced: true, min_version: "1.12" },
        { name: "netns", type: "string", tab: "basic",
          ui_label: "Network namespace", placeholder: "/var/run/netns/xx",
          advanced: true, min_version: "1.12" },

        { name: "disable_tcp_keep_alive", type: "bool", tab: "basic", default: 0,
          ui_label: "Disable TCP keep-alive", advanced: true, min_version: "1.13" },
        { name: "tcp_keep_alive", type: "string", tab: "basic",
          ui_label: "TCP keep-alive period", placeholder: "5m",
          advanced: true, min_version: "1.13" },
        { name: "tcp_keep_alive_interval", type: "string", tab: "basic",
          ui_label: "TCP keep-alive interval", placeholder: "75s",
          advanced: true, min_version: "1.13" },
    ],

    emit_spec: {
        merge: true,
        seq: [
            { name: "tcp_fast_open",          json_key: "tcp_fast_open",          coerce: "bool" },
            { name: "tcp_multi_path",         json_key: "tcp_multi_path",         coerce: "bool" },
            { name: "udp_fragment",           json_key: "udp_fragment",           coerce: "bool" },
            { name: "udp_timeout",            json_key: "udp_timeout" },
            { name: "detour",                 json_key: "detour" },
            { name: "bind_interface",         json_key: "bind_interface",         min_version: "1.12" },
            { name: "routing_mark",           json_key: "routing_mark",           coerce: "num", min_version: "1.12" },
            { name: "reuse_addr",             json_key: "reuse_addr",             coerce: "bool", min_version: "1.12" },
            { name: "netns",                  json_key: "netns",                  min_version: "1.12" },
            { name: "disable_tcp_keep_alive", json_key: "disable_tcp_keep_alive", coerce: "bool", min_version: "1.13" },
            { name: "tcp_keep_alive",         json_key: "tcp_keep_alive",         min_version: "1.13" },
            { name: "tcp_keep_alive_interval",json_key: "tcp_keep_alive_interval",min_version: "1.13" },
        ],
    },
};
