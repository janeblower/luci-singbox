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
    if (t === "bool") {
        let s = lc(v);
        return (s === "1" || s === "true") ? true : null;   // only set when truthy
    }
    if (t === "int") {
        let mm = match(v, /^[0-9]+/);
        if (!mm) return null;
        let n = +mm[0];
        return (type(n) === "int") ? n : null;
    }
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
        let v = coerce(params[e.param], e.transform);
        if (v == null) continue;
        set_path(out, e.path, v);
        if (e.enables != null) set_path(out, e.enables, true);
    }
    return out;
}

// INVENTORY / SPEC are filled in per scheme by later tasks.
const INVENTORY = {
    vless: [ "security", "sni", "type", "path", "host", "serviceName",
             "flow", "fp", "pbk", "sid", "alpn", "allowInsecure",
             "encryption", "spx", "mode", "headerType" ],
    trojan: [ "sni", "peer", "alpn", "allowInsecure", "allowinsecure", "fp",
              "type", "path", "host", "serviceName" ],
    hysteria2: [ "sni", "insecure", "alpn", "obfs", "obfs-password",
                 "pinSHA256", "mport", "up", "down" ],
    ss: [ "plugin" ],
    tuic: [ "congestion_control", "udp_relay_mode", "alpn", "sni",
            "allow_insecure", "disable_sni" ],
    hysteria: [ "auth", "peer", "insecure", "alpn", "up", "upmbps",
                "down", "downmbps", "obfs", "protocol" ],
    // vmess INVENTORY is the v2rayN base64-JSON key set, not URL query params.
    vmess: [ "v", "ps", "add", "port", "id", "aid", "scy",
             "net", "type", "host", "path", "tls", "sni", "alpn", "fp" ],
    anytls: [ "sni", "insecure", "alpn", "hpkp" ],
};

const SPEC = {
    vless: [
        // Delegated: TLS enable + default SNI, and the v2ray transport block,
        // are multi-param / context-dependent — handled by sharelink.uc helpers.
        { param: "security",    handler: "tls_security" },
        { param: "sni",         handler: "tls_security" },
        { param: "pbk",         handler: "tls_security" },
        { param: "sid",         handler: "tls_security" },
        { param: "type",        handler: "transport" },
        { param: "path",        handler: "transport" },
        { param: "host",        handler: "transport" },
        { param: "serviceName", handler: "transport" },
        // Direct:
        { param: "flow",         path: "flow" },
        { param: "fp",           path: "tls.utls.fingerprint", enables: "tls.utls.enabled",
                                 when: { security: ["tls", "reality"] } },
        { param: "alpn",         path: "tls.alpn", transform: "csv",
                                 when: { security: ["tls", "reality"] } },
        { param: "allowInsecure", path: "tls.insecure", transform: "bool",
                                 when: { security: ["tls", "reality"] } },
        // Unsupported (documented no-ops):
        { param: "encryption", unsupported: "sing-box VLESS has no encryption field (always none)" },
        { param: "spx",        unsupported: "Xray spider_x — no sing-box equivalent" },
        { param: "mode",       unsupported: "gRPC mode — no sing-box equivalent" },
        { param: "headerType", unsupported: "tcp/http header obfuscation — unsupported" },
    ],
    trojan: [
        { param: "type",        handler: "transport" },
        { param: "path",        handler: "transport" },
        { param: "host",        handler: "transport" },
        { param: "serviceName", handler: "transport" },
        // peer first, sni second so an explicit sni wins (last write).
        { param: "peer",         path: "tls.server_name" },
        { param: "sni",          path: "tls.server_name" },
        { param: "alpn",         path: "tls.alpn", transform: "csv" },
        { param: "allowInsecure", path: "tls.insecure", transform: "bool" },
        { param: "allowinsecure", path: "tls.insecure", transform: "bool" },
        { param: "fp",           path: "tls.utls.fingerprint", enables: "tls.utls.enabled" },
    ],
    hysteria2: [
        { param: "obfs",          handler: "obfs" },
        { param: "obfs-password", handler: "obfs" },
        { param: "sni",      path: "tls.server_name" },
        { param: "insecure", path: "tls.insecure", transform: "bool" },
        { param: "alpn",     path: "tls.alpn", transform: "csv" },
        { param: "pinSHA256", unsupported: "cert pinning — sing-box uses tls.certificate, not pin" },
        { param: "mport",     unsupported: "port hopping — sing-box server_ports format differs" },
        { param: "up",        unsupported: "client up bandwidth — server-advertised in sing-box" },
        { param: "down",      unsupported: "client down bandwidth — server-advertised in sing-box" },
    ],
    ss: [
        { param: "plugin", handler: "ss_plugin" },   // name;opts split is bespoke
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
        { param: "alpn", path: "tls.alpn", transform: "csv", when: { tls: "tls" } },
        { param: "fp",   path: "tls.utls.fingerprint", enables: "tls.utls.enabled", when: { tls: "tls" } },
        { param: "v",    unsupported: "v2rayN format-version marker — not a proxy field" },
    ],
};

return { INVENTORY, SPEC, apply_params, set_path, coerce };
