// lib/builder/protocols/tun.uc — TUN inbound under the E2 DSL.
//
// TUN is the alternative to tproxy, not a companion to it: with auto_route +
// auto_redirect sing-box installs its OWN nftables rules (and, per the docs,
// compatibility rules into the OpenWrt fw4 table), so our `inet singbox_ui`
// table is NOT used at all. Exactly one of {tun.auto_route, tproxy.nft_rules}
// may be on: both carry `exclusive: "transparent"`, so the form disables the
// loser's checkbox and names the owner, and generate.uc refuses to build (rc 3)
// if UCI says otherwise. See the comment on `auto_route` below — the polarity of
// the two flags differs and is load-bearing.
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

// AND, not just {auto_redirect:"1"} — and the difference is the whole point.
// `requires` reads the RAW UCI value of the sibling it names, never "would that
// sibling itself be emitted". auto_redirect is meaningless without auto_route
// (the core says so, and `requires: NEEDS_AUTO_ROUTE` on it enforces it), but
// switching auto_route off does NOT clear `auto_redirect '1'` from UCI — it
// just orphans it. A one-clause gate on auto_redirect therefore hands the
// orphan every field below: marks and address-sets emitted for a tunnel that
// routes nothing. Naming BOTH flags is what makes the gate mean what it reads
// like. (Fixture: tun_in_orphan_redirect.)
const NEEDS_AUTO_REDIRECT = [ { field: "auto_route",    value: "1" },
                              { field: "auto_redirect", value: "1" } ];

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
        // Exclusive group "transparent", shared with tproxy.nft_rules: exactly
        // one enabled inbound may own system routing / the firewall, and the two
        // claim it under DIFFERENT names by different means. descriptor_form's
        // makeExclusive() now scans every enabled inbound (not just siblings of
        // the same protocol) and resolves each one's flag against ITS OWN
        // descriptor `default` — which is the only reason this is safe to attach
        // here: an UNSET auto_route means OFF (default 0, see below), so a tun
        // that routes nothing does NOT seize the group and does NOT kill tproxy's
        // nft rules. The first version of the mechanism read unset as ON for
        // everything, which is right for nft_rules (default 1) and catastrophic
        // here; that is why this line was reverted once. Do not re-simplify the
        // polarity. Backend guard: generate.uc (helpers.transparent_conflict).
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
        // Nothing regresses out of the box: the seed config (etc/config/singbox-ui)
        // DOES ship a tun_in section (disabled), but it carries no auto_route or
        // auto_redirect — see the comment on tun_in there for why those two are
        // deliberately absent. `enabled` is a live grid checkbox, auto_route is
        // `modalonly`; if the seed pre-armed auto_route, ticking `enabled` alone
        // (never opening the modal) would make the disabled-by-default tun claim
        // system routing out from under the seeded, enabled tproxy_in and trip the
        // ownership conflict. A tun only starts routing once someone opens the
        // modal and ticks `auto_route` there themselves.
        // Guard: tests/backend/test_bool_default_polarity.test.ts,
        // tests/backend/test_defaults.test.ts ("enabling the seeded tun_in ...").
        { name: "auto_route", type: "bool", tab: "basic", default: 0,
          ui_label: "Auto route (own system routing)",
          json_key: "auto_route", coerce: "bool",
          exclusive: "transparent",
          ui_help: "Installs policy routing so traffic enters the tunnel. Mutually exclusive with the tproxy inbound's nftables rules." },

        // default: 0 for the same reason as auto_route (see above). It is also
        // what makes `requires: NEEDS_AUTO_ROUTE` work at all: `requires` reads the
        // RAW UCI value of the sibling, so an effectively-on-but-unset auto_route
        // would gate this field (and every other NEEDS_AUTO_ROUTE one) OFF.
        // requires_pkg: the ruleset sing-box installs here ends in an nfqueue
        // expression ("... queue flags bypass to 100" — verified on a live box
        // with `nft list table inet sing-box`), and the `queue` expression lives
        // in kmod-nft-queue. Nothing in a stock OpenWrt pulls that kmod in, and
        // the kernel does not ignore an expression it does not know: the WHOLE
        // batch is rejected with ENOENT, so sing-box dies at post-start with
        // "auto-redirect: setup nftables: flush nftables: ... no such file or
        // directory" and procd respawns it forever. `sing-box check` passes —
        // this is a runtime failure — so only the pkg note stands between the
        // operator and a service that silently never comes up. auto_route needs
        // no extra kmod (kmod-tun is already a hard dep); auto_redirect alone
        // does.
        { name: "auto_redirect", type: "bool", tab: "basic", default: 0,
          ui_label: "Auto redirect (nftables)",
          json_key: "auto_redirect", coerce: "bool",
          depends: NEEDS_AUTO_ROUTE, requires: NEEDS_AUTO_ROUTE,
          requires_pkg: "kmod-nft-queue",
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

        // Rule-set driven routes. These need BOTH auto_route AND auto_redirect,
        // and `sing-box check` will NOT tell you that: it accepts the config and
        // the daemon then dies at post-start. This file used to gate on
        // auto_route alone, citing exactly that green `check` — a static check
        // cannot see a runtime failure, so it was the wrong witness.
        //
        // What the core actually does (docs, tun/#route_address_set — two tabs):
        //   with auto_redirect    -> the CIDRs become an nftables set
        //   without auto_redirect -> the CIDRs become ROUTES, one per CIDR
        // and the route path blows up on the first duplicate CIDR. Our built-in
        // rule-sets overlap (they share Cloudflare/Meta ranges), so this is the
        // normal case, not a corner: bisected live on 1.13.12 —
        //   telegram                        -> starts
        //   telegram + meta                 -> starts
        //   telegram+meta+discord+twitter   -> FATAL "set routes: add route 8: file exists"
        // …and the tunnel never comes up, with nothing but that line to show.
        //
        // BOTH flags are named because `requires` is not transitive: it reads the
        // raw UCI value of the named sibling, never "would that sibling itself be
        // emitted". Gating on auto_redirect alone would let an orphaned
        // `auto_redirect '1'` (left behind when auto_route was switched off) leak
        // this field back into the config — that is the tun_in_orphan_redirect
        // fixture. Gating on auto_route alone is what shipped the FATAL above.
        //
        // A tag named here MUST end up in route.rule_set — see inbound.uc
        // referenced_rulesets(). Without it the core fails with
        // "parse route_address_set: rule-set not found: <tag>".
        { name: "route_address_set", type: "list", tab: "basic",
          ui_label: "Route via rule-sets", dynamic: "rulesets",
          json_key: "route_address_set", coerce: "array",
          depends: NEEDS_AUTO_REDIRECT, requires: NEEDS_AUTO_REDIRECT,
          ui_help: "Only traffic matching these rule-sets' IP CIDRs enters the tunnel; everything else bypasses it. The TUN counterpart of the tproxy nftables rules. Needs Auto redirect: without it sing-box turns each CIDR into a route and dies on the first duplicate." },
        { name: "route_exclude_address_set", type: "list", tab: "basic",
          ui_label: "Bypass via rule-sets", dynamic: "rulesets",
          json_key: "route_exclude_address_set", coerce: "array",
          depends: NEEDS_AUTO_REDIRECT, requires: NEEDS_AUTO_REDIRECT,
          ui_help: "Traffic matching these rule-sets' IP CIDRs bypasses the tunnel. Needs Auto redirect, same as the field above." },

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
