// lib/builder/_shared/route_action.uc — sing-box rule action fields, emitted
// FLAT (all action params live at the rule's top level). Each param carries
// BOTH `requires` (backend filler gate) and `depends` (frontend visibility),
// keyed on the `action` field. Override fields are shared by route +
// route-options via array-valued requires/depends.

const ROUTE_BOTH = [ "route", "route-options" ];
const BOTH_GATE = { field: "action", value: ROUTE_BOTH };

function fields() {
    return [
        { name: "action", type: "enum", tab: "action", required: true,
          json_key: "action", omit_when: "never", default: "route",
          // `default` is a UI-only default; the filler only consults
          // default_when_empty. Without it, a non-UI write (hand-edited UCI,
          // partial import) with no `action` value emits "action":"" which
          // sing-box rejects. Backfill the sing-box default "route" so
          // action_ok()'s outbound validation stays meaningful (BLD-1).
          default_when_empty: "route",
          values: [ "route", "route-options", "reject", "hijack-dns", "sniff", "resolve" ],
          ui_label: "Action" },

        // route
        { name: "outbound", type: "string", tab: "action", dynamic: "outbounds",
          json_key: "outbound", ui_label: "Outbound", required: true,
          requires: { field: "action", value: "route" },
          depends:  { field: "action", value: "route" } },

        // route + route-options overrides (advanced)
        { name: "override_address", type: "string", tab: "action", advanced: true,
          json_key: "override_address", ui_label: "Override address",
          requires: BOTH_GATE, depends: BOTH_GATE },
        { name: "override_port", type: "number", tab: "action", advanced: true,
          json_key: "override_port", coerce: "num", ui_label: "Override port",
          requires: BOTH_GATE, depends: BOTH_GATE },
        { name: "network_strategy", type: "string", tab: "action", advanced: true,
          json_key: "network_strategy", ui_label: "Network strategy",
          requires: BOTH_GATE, depends: BOTH_GATE },
        { name: "fallback_delay", type: "string", tab: "action", advanced: true,
          json_key: "fallback_delay", ui_label: "Fallback delay",
          requires: BOTH_GATE, depends: BOTH_GATE },
        { name: "udp_disable_domain_unmapping", type: "bool", tab: "action", advanced: true,
          json_key: "udp_disable_domain_unmapping", coerce: "bool",
          ui_label: "UDP disable domain unmapping",
          requires: BOTH_GATE, depends: BOTH_GATE },
        { name: "udp_connect", type: "bool", tab: "action", advanced: true,
          json_key: "udp_connect", coerce: "bool", ui_label: "UDP connect",
          requires: BOTH_GATE, depends: BOTH_GATE },
        { name: "udp_timeout", type: "string", tab: "action", advanced: true,
          json_key: "udp_timeout", ui_label: "UDP timeout",
          requires: BOTH_GATE, depends: BOTH_GATE },
        { name: "tls_fragment", type: "bool", tab: "action", advanced: true,
          json_key: "tls_fragment", coerce: "bool", min_version: "1.12",
          ui_label: "TLS fragment",
          requires: BOTH_GATE, depends: BOTH_GATE },
        { name: "tls_fragment_fallback_delay", type: "string", tab: "action", advanced: true,
          json_key: "tls_fragment_fallback_delay", min_version: "1.12",
          ui_label: "TLS fragment fallback delay",
          requires: BOTH_GATE, depends: BOTH_GATE },
        { name: "tls_record_fragment", type: "bool", tab: "action", advanced: true,
          json_key: "tls_record_fragment", coerce: "bool", min_version: "1.12",
          ui_label: "TLS record fragment",
          requires: BOTH_GATE, depends: BOTH_GATE },

        // reject
        { name: "method", type: "enum", tab: "action", json_key: "method",
          values: [ "default", "drop" ], default: "default", ui_label: "Reject method",
          requires: { field: "action", value: "reject" },
          depends:  { field: "action", value: "reject" } },
        { name: "no_drop", type: "bool", tab: "action", advanced: true,
          json_key: "no_drop", coerce: "bool", ui_label: "No drop",
          requires: { field: "action", value: "reject" },
          depends:  { field: "action", value: "reject" } },

        // hijack-dns — no sub-parameters in sing-box (action value only)

        // sniff
        { name: "sniffer", type: "list", tab: "action", json_key: "sniffer", coerce: "array",
          values: [ "http", "tls", "quic", "dns", "stun", "bittorrent", "dtls", "ssh", "rdp" ],
          ui_label: "Sniffer",
          requires: { field: "action", value: "sniff" },
          depends:  { field: "action", value: "sniff" } },
        { name: "timeout", type: "string", tab: "action", json_key: "timeout",
          ui_label: "Timeout",
          requires: { field: "action", value: [ "sniff", "resolve" ] },
          depends:  { field: "action", value: [ "sniff", "resolve" ] } },

        // resolve
        { name: "server", type: "string", tab: "action", dynamic: "dns_servers",
          json_key: "server", ui_label: "Resolve server",
          requires: { field: "action", value: "resolve" },
          depends:  { field: "action", value: "resolve" } },
        { name: "strategy", type: "enum", tab: "action", json_key: "strategy",
          values: [ "", "prefer_ipv4", "prefer_ipv6", "ipv4_only", "ipv6_only" ],
          ui_label: "Resolve strategy",
          requires: { field: "action", value: "resolve" },
          depends:  { field: "action", value: "resolve" } },
        { name: "disable_cache", type: "bool", tab: "action", advanced: true,
          json_key: "disable_cache", coerce: "bool", ui_label: "Disable cache",
          requires: { field: "action", value: "resolve" },
          depends:  { field: "action", value: "resolve" } },
        { name: "rewrite_ttl", type: "number", tab: "action", advanced: true,
          json_key: "rewrite_ttl", coerce: "num", ui_label: "Rewrite TTL",
          requires: { field: "action", value: "resolve" },
          depends:  { field: "action", value: "resolve" } },
        { name: "client_subnet", type: "string", tab: "action", advanced: true,
          json_key: "client_subnet", ui_label: "Client subnet",
          requires: { field: "action", value: "resolve" },
          depends:  { field: "action", value: "resolve" } },
    ];
}

return { fields };
