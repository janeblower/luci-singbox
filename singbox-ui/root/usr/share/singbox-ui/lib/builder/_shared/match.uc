// lib/builder/_shared/match.uc — single source of truth for sing-box rule
// matcher fields, shared by route_rule(default), logical sub-rules, and inline
// rule-set headless rules. Plain data module: matchers are ordinary scalar/list
// descriptors emitted by builder._filler (no emit_spec, NOT a SHARED_DISPATCH
// block). fields(ctx) returns shallow copies with the internal _ctx key removed.
//
// contexts:
//   "route"        — route rule top-level
//   "headless"     — route rule-set headless (minus rule_set/inbound/auth_user/clash_mode)
//   "dns"          — dns rule top-level
//   "dns_headless" — dns logical sub-rule (minus rule_set/inbound/auth_user/clash_mode/
//                    rule_set_ip_cidr_match_source)

// contexts:
//   "route" / "headless"   — route rule top-level / rule-set headless
//   "dns" / "dns_headless" — dns rule top-level / dns logical sub-rule
const FULL   = [ "route", "headless", "dns", "dns_headless" ]; // valid everywhere
const NO_HL  = [ "route", "dns" ];                 // not valid in any headless
const ROUTE  = [ "route", "headless" ];            // route-only (incl. route headless)
const DNS    = [ "dns", "dns_headless" ];          // dns-only, both
const DNS_TL = [ "dns" ];                          // dns-only, top-level only

// L: list/string-array matcher.  opts: {ctx, advanced?, values?, dynamic?, min_version?, max_version?, ui_label?}
function L(name, opts) {
    let f = { name: name, type: "list", tab: "match", json_key: name,
              coerce: "array", _ctx: opts.ctx };
    if (opts.advanced)    f.advanced = true;
    if (opts.values)      f.values = opts.values;
    if (opts.dynamic)     f.dynamic = opts.dynamic;
    if (opts.min_version) f.min_version = opts.min_version;
    if (opts.max_version) f.max_version = opts.max_version;
    if (opts.ui_label)    f.ui_label = opts.ui_label;
    return f;
}
// NL: numeric list (int array) matcher.
function NL(name, opts) { let f = L(name, opts); f.coerce = "num_array"; return f; }
// B: boolean matcher.
function B(name, opts) {
    let f = { name: name, type: "bool", tab: "match", json_key: name,
              coerce: "bool", _ctx: opts.ctx };
    if (opts.advanced)    f.advanced = true;
    if (opts.min_version) f.min_version = opts.min_version;
    if (opts.max_version) f.max_version = opts.max_version;
    if (opts.ui_label)    f.ui_label = opts.ui_label;
    return f;
}

// Declaration order = emit/render order.
const _FIELDS = [
    // -- common matchers (visible without advanced) --
    L("domain",          { ctx: FULL }),
    L("domain_suffix",   { ctx: FULL }),
    L("domain_keyword",  { ctx: FULL }),
    L("domain_regex",    { ctx: FULL }),
    L("ip_cidr",         { ctx: FULL }),
    L("source_ip_cidr",  { ctx: FULL }),
    NL("port",           { ctx: FULL }),
    L("port_range",      { ctx: FULL }),
    L("network",         { ctx: FULL, values: [ "tcp", "udp" ] }),
    L("protocol",        { ctx: FULL,
        values: [ "http", "tls", "quic", "dns", "stun", "bittorrent", "dtls", "ssh", "rdp" ] }),
    L("rule_set",        { ctx: NO_HL, dynamic: "rulesets", ui_label: "Rule-sets" }),

    // -- advanced matchers --
    L("inbound",         { ctx: NO_HL, advanced: true }),
    { name: "ip_version", type: "enum", tab: "match", json_key: "ip_version",
      coerce: "num", values: [ "4", "6" ], advanced: true, _ctx: FULL,
      ui_label: "IP version" },
    L("client",          { ctx: ROUTE, advanced: true, min_version: "1.10" }),
    L("auth_user",       { ctx: NO_HL, advanced: true }),
    NL("source_port",    { ctx: FULL, advanced: true }),
    L("source_port_range", { ctx: FULL, advanced: true }),
    L("process_name",    { ctx: FULL, advanced: true }),
    L("process_path",    { ctx: FULL, advanced: true }),
    L("process_path_regex", { ctx: FULL, advanced: true, min_version: "1.10" }),
    L("package_name",    { ctx: FULL, advanced: true }),
    L("package_name_regex", { ctx: FULL, advanced: true, min_version: "1.14" }),
    L("user",            { ctx: FULL, advanced: true }),
    NL("user_id",        { ctx: FULL, advanced: true }),
    { name: "clash_mode", type: "enum", tab: "match", json_key: "clash_mode",
      values: [ "", "global", "direct", "rule" ], advanced: true, _ctx: NO_HL,
      ui_label: "Clash mode" },
    L("network_type",    { ctx: FULL, advanced: true, min_version: "1.11",
        values: [ "wifi", "cellular", "ethernet", "other" ] }),
    B("network_is_expensive",   { ctx: FULL, advanced: true, min_version: "1.11" }),
    B("network_is_constrained", { ctx: FULL, advanced: true, min_version: "1.11" }),
    L("wifi_ssid",       { ctx: FULL, advanced: true }),
    L("wifi_bssid",      { ctx: FULL, advanced: true }),
    L("source_mac_address", { ctx: FULL, advanced: true, min_version: "1.14" }),
    L("source_hostname", { ctx: FULL, advanced: true, min_version: "1.14" }),
    B("ip_is_private",        { ctx: FULL, advanced: true }),
    B("source_ip_is_private", { ctx: FULL, advanced: true }),
    B("rule_set_ip_cidr_match_source",  { ctx: NO_HL, advanced: true }),
    B("rule_set_ip_cidr_accept_empty",  { ctx: NO_HL, advanced: true, min_version: "1.10", max_version: "1.16" }),
    // -- DNS-only matchers --
    L("query_type",      { ctx: DNS, ui_label: "Query type" }),
    B("ip_accept_any",   { ctx: DNS, advanced: true, min_version: "1.12" }),
    L("interface_address",         { ctx: DNS_TL, advanced: true, min_version: "1.13" }),
    L("network_interface_address", { ctx: DNS_TL, advanced: true, min_version: "1.13" }),
    L("default_interface_address", { ctx: DNS_TL, advanced: true, min_version: "1.13" }),
    L("preferred_by",    { ctx: DNS, advanced: true, min_version: "1.14" }),
    B("match_response",  { ctx: DNS, advanced: true, min_version: "1.14" }),
    L("response_rcode",  { ctx: DNS, advanced: true, min_version: "1.14",
        values: [ "NOERROR", "FORMERR", "SERVFAIL", "NXDOMAIN", "NOTIMP", "REFUSED" ] }),
    L("response_answer", { ctx: DNS, advanced: true, min_version: "1.14" }),
    L("response_ns",     { ctx: DNS, advanced: true, min_version: "1.14" }),
    L("response_extra",  { ctx: DNS, advanced: true, min_version: "1.14" }),
    B("invert",          { ctx: FULL, advanced: true }),
];

// fields(ctx) -> copies applicable to ctx, with _ctx stripped.
function fields(ctx) {
    let out = [];
    for (let f in _FIELDS) {
        let ok = false;
        for (let c in f._ctx) if (c === ctx) ok = true;
        if (!ok) continue;
        let copy = {};
        for (let k in keys(f)) if (k !== "_ctx") copy[k] = f[k];
        push(out, copy);
    }
    return out;
}

return { fields };
