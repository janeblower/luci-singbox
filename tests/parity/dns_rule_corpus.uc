// tests/parity/dns_rule_corpus.uc — dns_rule (default/logical) parity fixtures.
// Single-rule filler output (logical inlining is covered by test_dns_rule_dispatch.sh).
return [
    { name: "dnr_route_min", type: "default",
      section: { [".name"]: "r1", domain_suffix: [ ".cn" ], action: "route", server: "dns1" } },
    { name: "dnr_route_options", type: "default",
      section: { [".name"]: "r2", domain_keyword: [ "ads" ], action: "route-options",
                 disable_cache: "1", rewrite_ttl: "300" } },
    { name: "dnr_reject", type: "default",
      section: { [".name"]: "r3", domain: [ "blocked.example" ], action: "reject", method: "drop" } },
    { name: "dnr_predefined", type: "default",
      section: { [".name"]: "r4", domain: [ "nx.example" ], action: "predefined",
                 rcode: "NXDOMAIN", answer: [ "nx.example. 60 IN A 0.0.0.0" ] } },
    { name: "dnr_matchers", type: "default",
      section: { [".name"]: "r5", domain_suffix: [ ".cn" ], ip_cidr: [ "10.0.0.0/8" ],
                 network: [ "udp" ], query_type: [ "A", "AAAA" ], rule_set: [ "geoip-cn" ],
                 action: "route", server: "dns1" } },
    { name: "dnr_logical", type: "logical",
      section: { [".name"]: "r6", mode: "and", invert: "1", action: "route", server: "dns1" } },
];
