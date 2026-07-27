// lib/sharelink_map.uc — declarative share-link param → sing-box field maps.
//
// INVENTORY[scheme] is the authoritative list of every parameter the sharing
// standard defines for that scheme (the "skeleton"). SPEC[scheme] gives each
// param a disposition:
//   Direct      { param, path, transform?, when?, enables? }  -> apply_params writes it
//   Delegated   { param, handler:"name" }   -> a hand-written helper consumes it
//   Unsupported { param, unsupported:"why" } -> explicit no-op (documented drop)
// tests/test_sharelink_coverage.sh asserts the param sets of INVENTORY and SPEC
// are identical per scheme, so a param can never be silently dropped.
//
// SECURITY: this module never sanitizes untrusted bytes. Callers pass values
// already url-decoded + control-scrubbed; apply_params only writes
// string/array/bool/int leaves into an object it is given.

// set_path(obj, "a.b.c", v) — create nested objects along the dotted path,
// assign v at the leaf.
function set_path(obj, path, v) {
    let parts = split(path, ".");
    let cur = obj;
    for (let i = 0; i < length(parts) - 1; i++) {
        let k = parts[i];
        if (type(cur[k]) !== "object") cur[k] = {};
        cur = cur[k];
    }
    cur[parts[length(parts) - 1]] = v;
}

// is_true(v) — the truthiness every share-link producer agrees on. Providers
// emit insecure=yes / allowInsecure=on as readily as =1; accepting only 1|true
// silently dropped the flag (S5).
function is_true(v) {
    if (v == null) return false;
    if (type(v) === "bool") return v;
    let s = lc(`${v}`);
    return s === "1" || s === "true" || s === "yes" || s === "on";
}

// UTLS_FINGERPRINTS — the only values sing-box's utls.fingerprint accepts
// (common/tls/utls_client.go). A link carrying anything else (a typo, an
// Xray-only profile) must not reach sing-box: an unknown fingerprint is a FATAL
// config error, so normalise to chrome (S3).
//
// THIS IS THE ONE LIST. It used to disagree with the descriptor's enum and with
// the frontend importer's copy in both directions: `randomizedalpn` /
// `randomizednoalpn` are Xray names sing-box rejects (so the allowlist was
// waving through the exact thing it exists to stop), while `qq` and `random`
// are real sing-box values it was rewriting to chrome. Mihomo hands out
// `random` as a matter of course.
const UTLS_FINGERPRINTS = {
    chrome: true, firefox: true, edge: true, safari: true, "360": true,
    qq: true, ios: true, android: true, random: true, randomized: true,
};

function normalize_fp(v) {
    if (v == null) return "";
    let s = lc(`${v}`);
    // "none" is how Clash/Xray spell "no fingerprint at all" — it must come back
    // empty, not be rewritten to chrome (which would silently turn uTLS ON).
    if (!length(s) || s === "none") return "";
    return UTLS_FINGERPRINTS[s] ? s : "chrome";
}

// alpn_for_transport(list, transport) — the transport constrains the ALPN set:
// xhttp needs h2/http-1.1 even when the link says nothing, and ws/httpupgrade
// only ever speak HTTP/1.1 (S10).
function alpn_for_transport(list, transport) {
    let t = lc(`${transport ?? ""}`);
    if (t === "xhttp" && !length(list)) return [ "h2", "http/1.1" ];
    if ((t === "ws" || t === "httpupgrade") && length(list)) return [ "http/1.1" ];
    return list;
}

// coerce(v, t) — apply a transform. Returns null to signal "omit this field"
// (empty string, empty list, falsy bool, or non-numeric int).
function coerce(v, t) {
    if (v == null) return null;
    if (t == null || t === "str")
        return length(v) ? v : null;
    if (t === "csv") {
        let list = [];
        for (let a in split(v, ",")) { let x = trim(a); if (length(x)) push(list, x); }
        return length(list) ? list : null;
    }
    if (t === "bool")
        return is_true(v) ? true : null;                    // only set when truthy
    if (t === "int") {
        let mm = match(v, /^[0-9]+/);
        if (!mm) return null;
        let n = +mm[0];
        return (type(n) === "int") ? n : null;
    }
    if (t === "fp") {
        let f = normalize_fp(v);
        return length(f) ? f : null;
    }
    if (t === "penc")                                       // vless packet_encoding
        return (v === "xudp" || v === "packetaddr") ? v : null;
    if (t === "encryption")                                 // "none" == sing-box default
        return (length(v) && v !== "none") ? v : null;
    return length(v) ? v : null;
}

// gate_ok(params, when) — every key in `when` must match. A `when` value that is
// an array means OR (params[k] is any of them); a scalar means equality.
function gate_ok(params, when) {
    for (let k in when) {
        let want = when[k];
        if (type(want) === "array") {
            let found = false;
            for (let w in want) if (params[k] === w) { found = true; break; }
            if (!found) return false;
        } else if (params[k] !== want) {
            return false;
        }
    }
    return true;
}

// apply_params(params, entries, out) — for each Direct SPEC entry whose gate
// passes and whose param is present (after coercion), write into out at `path`.
// Delegated (handler) and Unsupported entries are no-ops here. Returns out.
function apply_params(params, entries, out) {
    for (let e in entries) {
        if (e.handler != null || e.unsupported != null) continue;   // not Direct
        if (e.when != null && !gate_ok(params, e.when)) continue;
        let v;
        if (e.transform === "alpn") {
            // ALPN is the one transform that depends on a sibling param (the
            // transport: `type` in a query, `net` in the vmess JSON).
            v = alpn_for_transport(coerce(params[e.param], "csv") ?? [],
                                   params["type"] ?? params["net"] ?? "");
            if (!length(v)) v = null;
        } else {
            v = coerce(params[e.param], e.transform);
        }
        if (v == null) continue;
        set_path(out, e.path, v);
        if (e.enables != null) set_path(out, e.enables, true);
    }
    return out;
}

// XHTTP_PARAMS — the Xray xhttp transport knobs. They arrive either as flat
// query params (camel or snake) or nested inside the JSON `extra` blob; both
// are consumed by the `transport` handler in sharelink.uc.
const XHTTP_PARAMS = [
    "mode", "extra", "xmux",
    "xPaddingBytes", "x_padding_bytes",
    "noGRPCHeader", "no_grpc_header",
    "scMaxEachPostBytes", "sc_max_each_post_bytes",
    "scMinPostsIntervalMs", "sc_min_posts_interval_ms",
    "scStreamUpServerSecs", "sc_stream_up_server_secs",
];

// INVENTORY / SPEC are filled in per scheme by later tasks.
const INVENTORY = {
    vless: [ "security", "sni", "peer", "type", "path", "host", "serviceName",
             "flow", "fp", "pbk", "sid", "alpn", "allowInsecure", "insecure",
             "encryption", "packetEncoding", "ed", "spx", "headerType",
             ...XHTTP_PARAMS ],
    trojan: [ "sni", "peer", "alpn", "allowInsecure", "allowinsecure", "fp",
              "type", "path", "host", "serviceName" ],
    hysteria2: [ "sni", "insecure", "allowInsecure", "alpn", "obfs",
                 "obfs-password", "pinSHA256", "mport", "up", "down",
                 "upmbps", "downmbps", "network" ],
    ss: [ "plugin", "plugin-opts" ],
    tuic: [ "congestion_control", "udp_relay_mode", "alpn", "sni",
            "allow_insecure", "disable_sni" ],
    hysteria: [ "auth", "peer", "insecure", "alpn", "up", "upmbps",
                "down", "downmbps", "obfs", "protocol" ],
    // vmess INVENTORY is the v2rayN base64-JSON key set, not URL query params.
    vmess: [ "v", "ps", "add", "port", "id", "aid", "scy",
             "net", "type", "host", "path", "tls", "sni", "alpn", "fp" ],
    anytls: [ "sni", "insecure", "alpn", "hpkp" ],
    socks: [ "udp" ],
};

const SPEC = {
    vless: [
        // Delegated: the whole TLS block (enable is inferred from sni/alpn/fp/pbk
        // when `security` is absent — see h_tls_security) and the v2ray/xhttp
        // transport block are multi-param / context-dependent.
        { param: "security",     handler: "tls_security" },
        { param: "sni",          handler: "tls_security" },
        { param: "peer",         handler: "tls_security" },   // sni alias
        { param: "pbk",          handler: "tls_security" },
        { param: "sid",          handler: "tls_security" },
        { param: "fp",           handler: "tls_security" },
        { param: "alpn",         handler: "tls_security" },
        { param: "allowInsecure", handler: "tls_security" },
        { param: "insecure",     handler: "tls_security" },   // allowInsecure alias
        { param: "type",         handler: "transport" },
        { param: "path",         handler: "transport" },
        { param: "host",         handler: "transport" },
        { param: "serviceName",  handler: "transport" },
        { param: "ed",           handler: "transport" },      // ws max_early_data
        // flow is whitelisted in parse_vless (an unknown flow rejects the link).
        { param: "flow",         handler: "flow" },
        // Direct:
        { param: "packetEncoding", path: "packet_encoding", transform: "penc" },
        { param: "encryption",     path: "encryption",       transform: "encryption" },
        // Unsupported (documented no-ops):
        { param: "spx",        unsupported: "Xray spider_x — no sing-box equivalent" },
        { param: "headerType", unsupported: "tcp/http header obfuscation — unsupported" },
        // xhttp knobs (mode/extra/xmux/sc*/x_padding/no_grpc_header):
        { param: "mode",                 handler: "transport" },
        { param: "extra",                handler: "transport" },
        { param: "xmux",                 handler: "transport" },
        { param: "xPaddingBytes",        handler: "transport" },
        { param: "x_padding_bytes",      handler: "transport" },
        { param: "noGRPCHeader",         handler: "transport" },
        { param: "no_grpc_header",       handler: "transport" },
        { param: "scMaxEachPostBytes",   handler: "transport" },
        { param: "sc_max_each_post_bytes", handler: "transport" },
        { param: "scMinPostsIntervalMs", handler: "transport" },
        { param: "sc_min_posts_interval_ms", handler: "transport" },
        { param: "scStreamUpServerSecs", handler: "transport" },
        { param: "sc_stream_up_server_secs", handler: "transport" },
    ],
    trojan: [
        { param: "type",        handler: "transport" },
        { param: "path",        handler: "transport" },
        { param: "host",        handler: "transport" },
        { param: "serviceName", handler: "transport" },
        // peer first, sni second so an explicit sni wins (last write).
        { param: "peer",         path: "tls.server_name" },
        { param: "sni",          path: "tls.server_name" },
        { param: "alpn",         path: "tls.alpn", transform: "alpn" },
        { param: "allowInsecure", path: "tls.insecure", transform: "bool" },
        { param: "allowinsecure", path: "tls.insecure", transform: "bool" },
        { param: "fp",           path: "tls.utls.fingerprint", enables: "tls.utls.enabled",
                                 transform: "fp" },
    ],
    hysteria2: [
        { param: "obfs",          handler: "obfs" },
        { param: "obfs-password", handler: "obfs" },
        { param: "mport",         handler: "ports" },   // port hopping -> server_ports
        { param: "sni",      path: "tls.server_name" },
        { param: "insecure",      path: "tls.insecure", transform: "bool" },
        { param: "allowInsecure", path: "tls.insecure", transform: "bool" },
        { param: "alpn",     path: "tls.alpn", transform: "csv" },
        { param: "upmbps",   path: "up_mbps",   transform: "int" },
        { param: "downmbps", path: "down_mbps", transform: "int" },
        { param: "network",  path: "network" },
        { param: "pinSHA256", unsupported: "cert pinning — sing-box uses tls.certificate, not pin" },
        { param: "up",        unsupported: "client up bandwidth — server-advertised in sing-box (use upmbps)" },
        { param: "down",      unsupported: "client down bandwidth — server-advertised in sing-box (use downmbps)" },
    ],
    ss: [
        { param: "plugin",      handler: "ss_plugin" },   // name;opts split is bespoke
        { param: "plugin-opts", handler: "ss_plugin" },   // SIP002 explicit opts
    ],
    tuic: [
        { param: "congestion_control", path: "congestion_control" },
        { param: "udp_relay_mode",     path: "udp_relay_mode" },
        { param: "sni",            path: "tls.server_name" },
        { param: "alpn",           path: "tls.alpn", transform: "csv" },
        { param: "allow_insecure", path: "tls.insecure", transform: "bool" },
        { param: "disable_sni",    path: "tls.disable_sni", transform: "bool" },
    ],
    hysteria: [
        { param: "auth",     path: "auth_str" },
        { param: "peer",     path: "tls.server_name" },
        { param: "insecure", path: "tls.insecure", transform: "bool" },
        { param: "alpn",     path: "tls.alpn", transform: "csv" },
        { param: "upmbps",   path: "up_mbps",   transform: "int" },
        { param: "up",       path: "up_mbps",   transform: "int" },
        { param: "downmbps", path: "down_mbps", transform: "int" },
        { param: "down",     path: "down_mbps", transform: "int" },
        { param: "obfs",     path: "obfs" },
        { param: "protocol", unsupported: "hysteria v1 transport protocol — sing-box is always QUIC" },
    ],
    anytls: [
        { param: "sni",      path: "tls.server_name" },
        { param: "insecure", path: "tls.insecure", transform: "bool" },
        { param: "alpn",     path: "tls.alpn", transform: "csv" },
        { param: "hpkp",     unsupported: "HPKP cert pinning — no sing-box equivalent" },
    ],
    socks: [
        { param: "udp", unsupported: "sing-box socks outbound is always UDP-capable" },
    ],
    vmess: [
        // Structural (parsed positionally in parse_vmess):
        { param: "add",  handler: "structural" },
        { param: "port", handler: "structural" },
        { param: "id",   handler: "structural" },
        { param: "ps",   handler: "structural" },
        { param: "aid",  handler: "structural" },
        { param: "scy",  handler: "structural" },
        { param: "net",  handler: "transport" },
        { param: "type", handler: "transport" },   // headerType
        { param: "host", handler: "transport" },
        { param: "path", handler: "transport" },
        { param: "tls",  handler: "tls" },          // "tls" string enables block
        { param: "sni",  handler: "tls" },
        // Direct (only when tls=="tls"):
        { param: "alpn", path: "tls.alpn", transform: "alpn", when: { tls: "tls" } },
        { param: "fp",   path: "tls.utls.fingerprint", enables: "tls.utls.enabled",
                         transform: "fp", when: { tls: "tls" } },
        { param: "v",    unsupported: "v2rayN format-version marker — not a proxy field" },
    ],
};

return { INVENTORY, SPEC, apply_params, set_path, coerce,
         is_true, normalize_fp, alpn_for_transport };
