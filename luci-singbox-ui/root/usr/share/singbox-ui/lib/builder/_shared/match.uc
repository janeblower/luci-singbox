// lib/builder/_shared/match.uc — single source of truth for sing-box rule
// matcher fields, shared by route_rule(default), logical sub-rules, and inline
// rule-set headless rules. Plain data module: matchers are ordinary scalar/list
// descriptors emitted by builder._filler (no emit_spec, NOT a SHARED_DISPATCH
// block). fields(ctx) returns shallow copies with the internal _ctx key removed.
//
// contexts:
//   "route"    — full set (top-level route rule)
//   "headless" — route minus rule_set/inbound/auth_user/clash_mode
//                (sing-box rejects those inside rule-set headless rules)
//   "dns"      — reserved for a future dns_rule unification (currently unused)

const FULL = [ "route", "headless", "dns" ];
const NO_HL = [ "route", "dns" ];   // not valid in headless rules

// L: list/string-array matcher.  opts: {ctx, advanced?, values?, dynamic?, min_version?, ui_label?}
function L(name, opts) {
    let f = { name: name, type: "list", tab: "match", json_key: name,
              coerce: "array", _ctx: opts.ctx };
    if (opts.advanced)    f.advanced = true;
    if (opts.values)      f.values = opts.values;
    if (opts.dynamic)     f.dynamic = opts.dynamic;
    if (opts.min_version) f.min_version = opts.min_version;
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
    L("client",          { ctx: FULL, advanced: true, min_version: "1.10" }),
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
    B("rule_set_ip_cidr_accept_empty",  { ctx: NO_HL, advanced: true, min_version: "1.10" }),
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
