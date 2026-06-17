// lib/builder/_shared/dns_action.uc — sing-box DNS rule action fields, emitted
// FLAT. Mirrors route_action.uc: each param carries `requires` (backend filler
// gate) + `depends` (frontend visibility), keyed on `action`. route/route-options
// share override fields via array-valued requires/depends.

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
          // validation stays meaningful.
          default_when_empty: "route",
          values: [ "route", "route-options", "reject", "predefined", "evaluate", "respond" ],
          ui_label: "Action" },

        // route: server selection (required for route action)
        { name: "server", type: "string", tab: "action", dynamic: "dns_servers",
          json_key: "server", ui_label: "Server",
          requires: { field: "action", value: "route" },
          depends:  { field: "action", value: "route" } },

        // route + route-options shared overrides
        { name: "strategy", type: "enum", tab: "action", advanced: true,
          json_key: "strategy", max_version: "1.16",
          values: [ "", "prefer_ipv4", "prefer_ipv6", "ipv4_only", "ipv6_only" ],
          ui_label: "Strategy", requires: BOTH_GATE, depends: BOTH_GATE },
        { name: "disable_cache", type: "bool", tab: "action", advanced: true,
          json_key: "disable_cache", coerce: "bool", ui_label: "Disable cache",
          requires: BOTH_GATE, depends: BOTH_GATE },
        { name: "disable_optimistic_cache", type: "bool", tab: "action", advanced: true,
          json_key: "disable_optimistic_cache", coerce: "bool", min_version: "1.14",
          ui_label: "Disable optimistic cache",
          requires: BOTH_GATE, depends: BOTH_GATE },
        { name: "rewrite_ttl", type: "number", tab: "action", advanced: true,
          json_key: "rewrite_ttl", coerce: "num", ui_label: "Rewrite TTL",
          requires: BOTH_GATE, depends: BOTH_GATE },
        { name: "timeout", type: "string", tab: "action", advanced: true,
          json_key: "timeout", min_version: "1.14", ui_label: "Timeout",
          requires: { field: "action", value: [ "route", "route-options", "evaluate" ] },
          depends:  { field: "action", value: [ "route", "route-options", "evaluate" ] } },
        { name: "client_subnet", type: "string", tab: "action", advanced: true,
          json_key: "client_subnet", ui_label: "Client subnet",
          requires: BOTH_GATE, depends: BOTH_GATE },

        // reject
        { name: "method", type: "enum", tab: "action", json_key: "method",
          values: [ "", "default", "drop" ], ui_label: "Reject method",
          requires: { field: "action", value: "reject" },
          depends:  { field: "action", value: "reject" } },
        { name: "no_drop", type: "bool", tab: "action", advanced: true,
          json_key: "no_drop", coerce: "bool", ui_label: "No drop",
          requires: { field: "action", value: "reject" },
          depends:  { field: "action", value: "reject" } },

        // predefined (1.12)
        { name: "rcode", type: "enum", tab: "action", json_key: "rcode", min_version: "1.12",
          values: [ "", "NOERROR", "FORMERR", "SERVFAIL", "NXDOMAIN", "NOTIMP", "REFUSED" ],
          ui_label: "Response code",
          requires: { field: "action", value: "predefined" },
          depends:  { field: "action", value: "predefined" } },
        { name: "answer", type: "list", tab: "action", json_key: "answer", coerce: "array",
          min_version: "1.12", ui_label: "Answer records",
          requires: { field: "action", value: "predefined" },
          depends:  { field: "action", value: "predefined" } },
        { name: "ns", type: "list", tab: "action", json_key: "ns", coerce: "array",
          min_version: "1.12", ui_label: "NS records",
          requires: { field: "action", value: "predefined" },
          depends:  { field: "action", value: "predefined" } },
        { name: "extra", type: "list", tab: "action", json_key: "extra", coerce: "array",
          min_version: "1.12", ui_label: "Extra records",
          requires: { field: "action", value: "predefined" },
          depends:  { field: "action", value: "predefined" } },

        // evaluate (1.14): distinct field name to avoid colliding with the
        // route/route-options disable_optimistic_cache above; same json_key,
        // mutually exclusive via the action gate. timeout (above) also gates evaluate.
        { name: "evaluate_disable_optimistic_cache", type: "bool", tab: "action", advanced: true,
          json_key: "disable_optimistic_cache", coerce: "bool", min_version: "1.14",
          ui_label: "Disable optimistic cache (evaluate)",
          requires: { field: "action", value: "evaluate" },
          depends:  { field: "action", value: "evaluate" } },

        // respond (1.14): no sub-options (action value only)
    ];
}

return { fields };
