// tests/parity/route_corpus.uc — route_rule + rule_set parity fixtures.
// Each fixture builds a tiny UCI tree (route_rule / ruleset sections) and has a
// hand-verified golden under tests/parity/golden/. `kind` selects which builder
// output to canon-compare: "rule" -> route.build_route_rules(...).rules[0];
// "ruleset" -> ruleset.build_rule_sets(...) entry for `tag`.
return [
    { name: "route_domain_to_outbound", kind: "rule", tag: null,
      sections: [
        { type: "route_rule", name: "r1",
          opts: { enabled: "1", type: "default", action: "route", outbound: "proxy" },
          lists: { domain_suffix: [ "example.com" ], port: [ "443" ] } },
        { type: "outbound", name: "proxy", opts: { type: "vless" }, lists: {} },
      ] },
    { name: "route_reject", kind: "rule", tag: null,
      sections: [
        { type: "route_rule", name: "r1",
          opts: { enabled: "1", type: "default", action: "reject", method: "drop" },
          lists: { ip_cidr: [ "10.0.0.0/8" ] } },
      ] },
    { name: "route_sniff", kind: "rule", tag: null,
      sections: [
        { type: "route_rule", name: "r1",
          opts: { enabled: "1", type: "default", action: "sniff", timeout: "500ms" },
          lists: { sniffer: [ "tls", "http" ] } },
      ] },
    { name: "rs_remote", kind: "ruleset", tag: "geosite",
      sections: [
        { type: "ruleset", name: "geosite",
          opts: { enabled: "1", type: "remote",
                  url: "https://example.com/geosite.srs", update_interval: "86400" },
          lists: {} },
        { type: "route_rule", name: "r1",
          opts: { enabled: "1", type: "default", action: "route", outbound: "proxy" },
          lists: { rule_set: [ "geosite" ] } },
        { type: "outbound", name: "proxy", opts: { type: "vless" }, lists: {} },
      ] },
    { name: "rs_inline", kind: "ruleset", tag: "blocklist",
      sections: [
        { type: "ruleset", name: "blocklist",
          opts: { enabled: "1", type: "inline" }, lists: { rules: [ "h1" ] } },
        { type: "route_rule", name: "h1",
          opts: { enabled: "1", type: "default", action: "route", outbound: "proxy" },
          lists: { domain_suffix: [ "ads.example" ] } },
        { type: "route_rule", name: "r1",
          opts: { enabled: "1", type: "default", action: "reject" },
          lists: { rule_set: [ "blocklist" ] } },
        { type: "outbound", name: "proxy", opts: { type: "vless" }, lists: {} },
      ] },
];
