// lib/builder/protocols/tun.uc — TUN inbound under the E2 DSL.
//
// TUN is the alternative to tproxy, not a companion to it: with auto_route +
// auto_redirect sing-box installs its OWN nftables rules (and, per the docs,
// compatibility rules into the OpenWrt fw4 table), so our `inet singbox_ui`
// table is NOT used at all. Only one of {tun.auto_route, tproxy.nft_rules}
// should really be on at once, but there is NO enforced cross-protocol
// exclusivity today — see the comment on `auto_route` below for why
// `exclusive: "transparent"` was tried and reverted. A later task builds a
// group-aware, polarity-aware mechanism and wires the two together.
//
// NO shared: { listen: true }. tun is not a listener. The doc page renders a
// "Listen Fields" section but that is a doc-generator artifact: sing-box 1.13.13
// rejects listen / listen_port / tcp_fast_open / udp_fragment / detour /
// bind_interface / routing_mark / reuse_addr / netns / tcp_keep_alive* on a tun
// inbound with `json: unknown field` and refuses the whole config. `udp_timeout`
// is the only one it accepts — declared below.
//
// NOT emitted, on purpose:
//   include_package / exclude_package / include_android_user — Android-only, no-op here
//   platform.http_proxy                                      — Android/Apple VPN clients
//   gso                                                      — deprecated 1.11, REMOVED 1.12
//   inet4_address / inet6_address / inet4_route_* / inet6_route_*
//                                                            — deprecated 1.10, REMOVED 1.12
// The last two are not a "saving": 1.13 rejects them with an explicit
// deprecation error, so emitting them would break the config outright.
//
// Every field below was verified against a live core (`sing-box check`, 1.13.13).
//
// `depends` (frontend visibility) and `requires` (backend emission) are BOTH
// needed. Turning auto_route off leaves `auto_redirect '1'` behind in UCI; the
// `requires` gate is what stops us emitting an orphan auto_redirect that the
// core would reject.

let reg = require("builder.protocols.registry");

const NEEDS_AUTO_ROUTE    = { field: "auto_route",    value: "1" };
const NEEDS_AUTO_REDIRECT = { field: "auto_redirect", value: "1" };

reg.register({
    kind: "inbound", type: "tun", sing_box_type: "tun",

    fields: [
        { name: "interface_name", type: "string", tab: "basic",
          ui_label: "Interface name", placeholder: "singbox-tun",
          json_key: "interface_name",
          ui_help: "Leave empty to let sing-box pick one (tun0, tun1, ...)." },

        { name: "address", type: "list", tab: "basic", required: true,
          ui_label: "Interface address (CIDR)",
          json_key: "address", coerce: "array",
          ui_help: "IPv4 and/or IPv6 prefix for the tun device, e.g. 172.19.0.1/30 and fdfe:dcba:9876::1/126." },

        { name: "mtu", type: "number", tab: "basic",
          ui_label: "MTU", placeholder: "9000",
          json_key: "mtu", coerce: "num" },

        { name: "stack", type: "enum", tab: "basic",
          values: ["", "system", "gvisor", "mixed"], default: "",
          ui_label: "TCP/IP stack", json_key: "stack",
          only_values: ["system", "gvisor", "mixed"],
          ui_help: "Empty = let sing-box choose (mixed when built with gVisor, otherwise system)." },

        // --- Ownership of system routing / firewall -------------------------
        // NOT wired to tproxy.nft_rules (yet). `exclusive: "transparent"` was
        // tried here and reverted: descriptor_form.js's makeExclusive() filters
        // sibling sections by `protocol`, so a shared group LABEL buys no
        // cross-protocol semantics — it only ever compared tun sections against
        // other tun sections. Worse, its ownerOf() treats an UNSET flag as
        // owner-qualifying, which is correct for tproxy.nft_rules (default:1, no
        // json_key, so unset really does mean "on, not yet saved") and backwards
        // for auto_route (default:0 — see below, unset means OFF): a tun_a with
        // auto_route left OFF would still have "owned" the group and force every
        // other tun section's auto_route to a disabled, forced-off checkbox. A
        // later task builds a group-aware, polarity-aware exclusive mechanism and
        // re-attaches it here together with tproxy.
        //
        // `default: 0` IS DELIBERATE — do not "helpfully" flip it back to 1.
        // LuCI's CBIAbstractValue.parse() REMOVES an option whose submitted value
        // equals its `default` (when rmempty/optional, and descriptor_form only
        // clears rmempty for `required` fields). With default:1, a user who ticks
        // the box — or just leaves it ticked — writes NOTHING to UCI, and
        // _filler's bool branch emits only when the UCI value is exactly "1" ⇒ the
        // tun would route nothing while every unset-means-on predicate believed it
        // did. So: default 0 ⇒ ticked means an explicit `auto_route '1'` in UCI,
        // unticked means UNSET, and UNSET MEANS OFF.
        // Any ownership predicate over these two flags must therefore test
        // `=== "1"`. (tproxy.nft_rules keeps default:1 and is safe only because it
        // has no json_key — nothing emits it — so its `!== "0"` polarity is right
        // for IT and wrong here. Do not copy it over.)
        // The seed config ships `option auto_route '1'` explicitly, so out-of-box
        // behaviour is unchanged; a freshly ADDED tun no longer seizes system
        // routing before the user asks for it.
        // Guard: tests/backend/test_bool_default_polarity.test.ts.
        { name: "auto_route", type: "bool", tab: "basic", default: 0,
          ui_label: "Auto route (own system routing)",
          json_key: "auto_route", coerce: "bool",
          ui_help: "Installs policy routing so traffic enters the tunnel. Mutually exclusive with the tproxy inbound's nftables rules." },

        // default: 0 for the same reason as auto_route (see above). It is also
        // what makes `requires: NEEDS_AUTO_ROUTE` work at all: `requires` reads the
        // RAW UCI value of the sibling, so an effectively-on-but-unset auto_route
        // would gate this field (and every other NEEDS_AUTO_ROUTE one) OFF.
        { name: "auto_redirect", type: "bool", tab: "basic", default: 0,
          ui_label: "Auto redirect (nftables)",
          json_key: "auto_redirect", coerce: "bool",
          depends: NEEDS_AUTO_ROUTE, requires: NEEDS_AUTO_ROUTE,
          ui_help: "sing-box installs its own nftables rules, including compatibility rules for the OpenWrt fw4 table. Recommended: better routing and higher performance than tproxy." },

        { name: "strict_route", type: "bool", tab: "basic", default: 0,
          ui_label: "Strict route",
          json_key: "strict_route", coerce: "bool",
          depends: NEEDS_AUTO_ROUTE, requires: NEEDS_AUTO_ROUTE },

        // --- nftables / marks (auto_redirect) --------------------------------
        { name: "auto_redirect_input_mark", type: "string", tab: "basic",
          ui_label: "Auto-redirect input mark", placeholder: "0x2023",
          json_key: "auto_redirect_input_mark", advanced: true,
          depends: NEEDS_AUTO_REDIRECT, requires: NEEDS_AUTO_REDIRECT },
        { name: "auto_redirect_output_mark", type: "string", tab: "basic",
          ui_label: "Auto-redirect output mark", placeholder: "0x2024",
          json_key: "auto_redirect_output_mark", advanced: true,
          depends: NEEDS_AUTO_REDIRECT, requires: NEEDS_AUTO_REDIRECT },
        { name: "auto_redirect_reset_mark", type: "string", tab: "basic",
          ui_label: "Auto-redirect reset mark", placeholder: "0x2025",
          json_key: "auto_redirect_reset_mark", advanced: true, min_version: "1.13",
          depends: NEEDS_AUTO_REDIRECT, requires: NEEDS_AUTO_REDIRECT },
        { name: "auto_redirect_nfqueue", type: "number", tab: "basic",
          ui_label: "Auto-redirect nfqueue", placeholder: "100",
          json_key: "auto_redirect_nfqueue", coerce: "num", advanced: true, min_version: "1.13",
          depends: NEEDS_AUTO_REDIRECT, requires: NEEDS_AUTO_REDIRECT },
        { name: "auto_redirect_iproute2_fallback_rule_index", type: "number", tab: "basic",
          ui_label: "Auto-redirect iproute2 fallback rule index", placeholder: "32768",
          json_key: "auto_redirect_iproute2_fallback_rule_index", coerce: "num",
          advanced: true, min_version: "1.13",
          depends: NEEDS_AUTO_REDIRECT, requires: NEEDS_AUTO_REDIRECT },
        { name: "exclude_mptcp", type: "bool", tab: "basic", default: 0,
          ui_label: "Exclude MPTCP",
          json_key: "exclude_mptcp", coerce: "bool", advanced: true, min_version: "1.13",
          depends: NEEDS_AUTO_REDIRECT, requires: NEEDS_AUTO_REDIRECT },

        // --- iproute2 ---------------------------------------------------------
        { name: "iproute2_table_index", type: "number", tab: "basic",
          ui_label: "iproute2 table index", placeholder: "2022",
          json_key: "iproute2_table_index", coerce: "num", advanced: true,
          depends: NEEDS_AUTO_ROUTE, requires: NEEDS_AUTO_ROUTE },
        { name: "iproute2_rule_index", type: "number", tab: "basic",
          ui_label: "iproute2 rule index", placeholder: "9000",
          json_key: "iproute2_rule_index", coerce: "num", advanced: true,
          depends: NEEDS_AUTO_ROUTE, requires: NEEDS_AUTO_ROUTE },
        { name: "loopback_address", type: "list", tab: "basic",
          ui_label: "Loopback address",
          json_key: "loopback_address", coerce: "array", advanced: true, min_version: "1.12" },

        // --- routes -----------------------------------------------------------
        // Interface rules require auto_route (docs). include_/exclude_ conflict
        // with each other — sing-box rejects the pair, and `sing-box check` in
        // init.d catches it before the daemon starts, so no hard guard here.
        { name: "include_interface", type: "list", tab: "basic",
          ui_label: "Include interfaces", dynamic: "devices",
          json_key: "include_interface", coerce: "array", advanced: true,
          depends: NEEDS_AUTO_ROUTE, requires: NEEDS_AUTO_ROUTE,
          ui_help: "Conflicts with 'Exclude interfaces' — set only one of the two." },
        { name: "exclude_interface", type: "list", tab: "basic",
          ui_label: "Exclude interfaces", dynamic: "devices",
          json_key: "exclude_interface", coerce: "array", advanced: true,
          depends: NEEDS_AUTO_ROUTE, requires: NEEDS_AUTO_ROUTE,
          ui_help: "With strict_route on, return traffic to excluded interfaces is not excluded automatically — add them here too (e.g. br-lan, pppoe-wan). Conflicts with 'Include interfaces'." },

        { name: "route_address", type: "list", tab: "basic",
          ui_label: "Route address (CIDR)",
          json_key: "route_address", coerce: "array", advanced: true,
          depends: NEEDS_AUTO_ROUTE, requires: NEEDS_AUTO_ROUTE },
        { name: "route_exclude_address", type: "list", tab: "basic",
          ui_label: "Route exclude address (CIDR)",
          json_key: "route_exclude_address", coerce: "array", advanced: true,
          depends: NEEDS_AUTO_ROUTE, requires: NEEDS_AUTO_ROUTE },

        // Rule-set driven routes. The docs claim these require BOTH auto_route
        // and auto_redirect, but a live `sing-box check` (1.13.13) accepts
        // route_address_set with only auto_route set (auto_redirect entirely
        // absent) — trust the core, not the doc page, per this file's own rule.
        // Gate on auto_route alone, and NOT auto_redirect: `requires` checks the
        // raw UCI value of the named sibling, not whether that sibling would
        // itself be emitted, so gating on auto_redirect here does not
        // transitively pick up auto_route — an orphaned `auto_redirect '1'` left
        // behind after the user flips auto_route off would leak this field back
        // into the config (see tun_in_orphan_redirect).
        // A tag named here MUST end up in route.rule_set — see inbound.uc
        // referenced_rulesets(). Without it the core fails with
        // "parse route_address_set: rule-set not found: <tag>".
        { name: "route_address_set", type: "list", tab: "basic",
          ui_label: "Route via rule-sets", dynamic: "rulesets",
          json_key: "route_address_set", coerce: "array",
          depends: NEEDS_AUTO_ROUTE, requires: NEEDS_AUTO_ROUTE,
          ui_help: "Only traffic matching these rule-sets' IP CIDRs enters the tunnel; everything else bypasses it. The TUN counterpart of the tproxy nftables rules." },
        { name: "route_exclude_address_set", type: "list", tab: "basic",
          ui_label: "Bypass via rule-sets", dynamic: "rulesets",
          json_key: "route_exclude_address_set", coerce: "array",
          depends: NEEDS_AUTO_ROUTE, requires: NEEDS_AUTO_ROUTE,
          ui_help: "Traffic matching these rule-sets' IP CIDRs bypasses the tunnel." },

        // --- uid rules ----------------------------------------------------------
        { name: "include_uid", type: "list", tab: "basic",
          ui_label: "Include UIDs",
          json_key: "include_uid", coerce: "num_array", advanced: true,
          depends: NEEDS_AUTO_ROUTE, requires: NEEDS_AUTO_ROUTE },
        { name: "exclude_uid", type: "list", tab: "basic",
          ui_label: "Exclude UIDs",
          json_key: "exclude_uid", coerce: "num_array", advanced: true,
          depends: NEEDS_AUTO_ROUTE, requires: NEEDS_AUTO_ROUTE },
        { name: "include_uid_range", type: "list", tab: "basic",
          ui_label: "Include UID ranges", placeholder: "1000:2000",
          json_key: "include_uid_range", coerce: "array", advanced: true,
          depends: NEEDS_AUTO_ROUTE, requires: NEEDS_AUTO_ROUTE },
        { name: "exclude_uid_range", type: "list", tab: "basic",
          ui_label: "Exclude UID ranges", placeholder: "1000:2000",
          json_key: "exclude_uid_range", coerce: "array", advanced: true,
          depends: NEEDS_AUTO_ROUTE, requires: NEEDS_AUTO_ROUTE },

        // --- misc ---------------------------------------------------------------
        // The ONLY listen-ish key the core accepts on tun (verified).
        { name: "udp_timeout", type: "string", tab: "basic",
          ui_label: "UDP NAT timeout", placeholder: "5m",
          json_key: "udp_timeout", advanced: true },
        // Docs: only available on the gvisor stack; other stacks are
        // endpoint-independent by default.
        { name: "endpoint_independent_nat", type: "bool", tab: "basic", default: 0,
          ui_label: "Endpoint-independent NAT",
          json_key: "endpoint_independent_nat", coerce: "bool", advanced: true,
          depends: { field: "stack", value: ["gvisor", "mixed"] },
          requires: { field: "stack", value: ["gvisor", "mixed"] } },

        // --- UI/UCI-only (no json_key) --------------------------------------------
        // Consumed by route.uc, which emits {protocol:"dns", action:"hijack-dns"}.
        // NOT `virtual`: descriptor_form.makeVirtual() write-suppresses virtual
        // fields, which would silently discard every modal edit (see tproxy.uc).
        { name: "hijack_dns", type: "bool", tab: "basic", default: 0,
          ui_label: "Hijack DNS",
          ui_help: "Route DNS queries entering the tunnel into sing-box's own DNS module." },
    ],
});

return {};
