// lib/protocols/_shared/tls.uc

let helpers = require("helpers");
const s_opt   = helpers.s_opt;
const s_bool  = helpers.s_bool;
const s_num   = helpers.s_num;
const as_array = helpers.as_array;

function _common_payload(s) {
    let tls = { enabled: true };
    if (length(s_opt(s, "tls_server_name")))
        tls.server_name = s.tls_server_name;
    if (s_bool(s, "tls_insecure"))
        tls.insecure = true;
    let alpn = as_array(s.tls_alpn);
    if (length(alpn))
        tls.alpn = alpn;
    if (length(s_opt(s, "tls_min_version")))
        tls.min_version = s.tls_min_version;
    if (length(s_opt(s, "tls_max_version")))
        tls.max_version = s.tls_max_version;
    let ciphers = as_array(s.tls_cipher_suites);
    if (length(ciphers))
        tls.cipher_suites = ciphers;
    return tls;
}

function _maybe_utls(tls, s) {
    if (!s_bool(s, "utls_enabled")) return;
    tls.utls = {
        enabled: true,
        fingerprint: length(s_opt(s, "utls_fingerprint")) ? s.utls_fingerprint : "chrome",
    };
}

function _maybe_ech_outbound(tls, s) {
    if (!s_bool(s, "tls_ech_enabled")) return;
    let ech = { enabled: true };
    let cfg = as_array(s.tls_ech_config);
    if (length(cfg)) ech.config = cfg;
    if (length(s_opt(s, "tls_ech_config_path"))) ech.config_path = s.tls_ech_config_path;
    tls.ech = ech;
}

function _maybe_ech_inbound(tls, s) {
    if (!s_bool(s, "tls_ech_enabled")) return;
    let ech = { enabled: true };
    let key = as_array(s.tls_ech_key);
    if (length(key)) ech.key = key;
    if (length(s_opt(s, "tls_ech_key_path"))) ech.key_path = s.tls_ech_key_path;
    tls.ech = ech;
}

function _maybe_fragment(tls, s) {
    if (s_bool(s, "tls_fragment")) tls.fragment = true;
    if (length(s_opt(s, "tls_fragment_fallback_delay")))
        tls.fragment_fallback_delay = s.tls_fragment_fallback_delay;
    if (s_bool(s, "tls_record_fragment")) tls.record_fragment = true;
}

function _maybe_reality_outbound(tls, s) {
    if (!s_bool(s, "reality_enabled")) return;
    let r = { enabled: true };
    if (length(s_opt(s, "reality_public_key"))) r.public_key = s.reality_public_key;
    if (length(s_opt(s, "reality_short_id")))   r.short_id   = s.reality_short_id;
    tls.reality = r;
}

function _maybe_reality_inbound(tls, s) {
    if (!s_bool(s, "reality_enabled")) return;
    let r = { enabled: true };
    if (length(s_opt(s, "reality_private_key"))) r.private_key = s.reality_private_key;
    if (length(s_opt(s, "reality_short_id")))    r.short_id    = s.reality_short_id;
    let hs = {};
    if (length(s_opt(s, "reality_handshake_server")))
        hs.server = s.reality_handshake_server;
    if (length(s_opt(s, "reality_handshake_server_port")))
        hs.server_port = s_num(s.reality_handshake_server_port);
    if (length(keys(hs))) r.handshake = hs;
    tls.reality = r;
}

function emit_outbound(s, opts) {
    if (!s_bool(s, "tls_enabled") && !(opts && opts.force_enabled)) return null;
    let tls = _common_payload(s);
    _maybe_utls(tls, s);
    _maybe_ech_outbound(tls, s);
    _maybe_fragment(tls, s);
    _maybe_reality_outbound(tls, s);
    return tls;
}

function emit_inbound(s, opts) {
    if (!s_bool(s, "tls_enabled") && !(opts && opts.force_enabled)) return null;
    let tls = _common_payload(s);
    if (length(s_opt(s, "tls_certificate_path"))) tls.certificate_path = s.tls_certificate_path;
    if (length(s_opt(s, "tls_key_path")))         tls.key_path         = s.tls_key_path;
    _maybe_ech_inbound(tls, s);
    _maybe_reality_inbound(tls, s);
    return tls;
}

return {
    applies_to: { kinds: [ "inbound", "outbound" ] },

    fields: [
        { name: "tls_enabled", type: "bool", tab: "tls",
          ui_label: "Enable TLS", default: 0 },
        { name: "tls_server_name", type: "string", tab: "tls",
          ui_label: "Server name (SNI)", placeholder: "example.com",
          parent_enabled: "tls_enabled" },
        { name: "tls_insecure", type: "bool", tab: "tls",
          ui_label: "Skip certificate verification", default: 0,
          parent_enabled: "tls_enabled" },

        { name: "tls_alpn", type: "list", tab: "tls",
          ui_label: "ALPN", placeholder: "h2 / http/1.1",
          values: ["h2", "http/1.1", "h3"],
          parent_enabled: "tls_enabled", advanced: true },
        { name: "tls_min_version", type: "enum", tab: "tls",
          ui_label: "TLS min version", values: ["", "1.0", "1.1", "1.2", "1.3"],
          default: "1.2", parent_enabled: "tls_enabled", advanced: true },
        { name: "tls_max_version", type: "enum", tab: "tls",
          ui_label: "TLS max version", values: ["", "1.0", "1.1", "1.2", "1.3"],
          default: "1.3", parent_enabled: "tls_enabled", advanced: true },
        { name: "tls_cipher_suites", type: "list", tab: "tls",
          ui_label: "Cipher suites",
          values: ["TLS_AES_128_GCM_SHA256", "TLS_AES_256_GCM_SHA384",
                   "TLS_CHACHA20_POLY1305_SHA256",
                   "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256",
                   "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256",
                   "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384",
                   "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384",
                   "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256",
                   "TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256"],
          parent_enabled: "tls_enabled", advanced: true },
        { name: "tls_certificate_path", type: "string", tab: "tls",
          ui_label: "Server certificate path",
          parent_enabled: "tls_enabled", advanced: true },
        { name: "tls_key_path", type: "string", tab: "tls",
          ui_label: "Server key path",
          parent_enabled: "tls_enabled", advanced: true },

        { name: "utls_enabled", type: "bool", tab: "tls",
          ui_label: "Enable uTLS fingerprint",
          parent_enabled: "tls_enabled", advanced: true, default: 0 },
        { name: "utls_fingerprint", type: "enum", tab: "tls",
          ui_label: "uTLS fingerprint",
          values: ["chrome", "firefox", "safari", "ios", "android", "edge", "360", "qq", "random"],
          default: "chrome",
          parent_enabled: "utls_enabled", advanced: true },

        // Since sing-box 1.12: fragment applies to outbound/client only.
        { name: "tls_fragment", type: "bool", tab: "tls",
          ui_label: "Fragment ClientHello",
          parent_enabled: "tls_enabled", advanced: true, default: 0 },
        { name: "tls_fragment_fallback_delay", type: "string", tab: "tls",
          ui_label: "Fragment fallback delay",
          placeholder: "500ms",
          parent_enabled: "tls_fragment", advanced: true },
        { name: "tls_record_fragment", type: "bool", tab: "tls",
          ui_label: "Record fragment",
          parent_enabled: "tls_enabled", advanced: true, default: 0 },

        { name: "tls_ech_enabled", type: "bool", tab: "tls",
          ui_label: "Enable ECH",
          parent_enabled: "tls_enabled", advanced: true, default: 0 },
        { name: "tls_ech_config", type: "list", tab: "tls",
          ui_label: "ECH config (client)",
          parent_enabled: "tls_ech_enabled", advanced: true },
        { name: "tls_ech_config_path", type: "string", tab: "tls",
          ui_label: "ECH config path (client)",
          parent_enabled: "tls_ech_enabled", advanced: true },
        { name: "tls_ech_key", type: "list", tab: "tls",
          ui_label: "ECH key (server)",
          parent_enabled: "tls_ech_enabled", advanced: true },
        { name: "tls_ech_key_path", type: "string", tab: "tls",
          ui_label: "ECH key path (server)",
          parent_enabled: "tls_ech_enabled", advanced: true },

        { name: "reality_enabled", type: "bool", tab: "tls",
          ui_label: "Enable Reality",
          parent_enabled: "tls_enabled", advanced: true, default: 0 },
        { name: "reality_public_key", type: "string", tab: "tls",
          ui_label: "Reality public key (client)", secret: true,
          parent_enabled: "reality_enabled", advanced: true },
        { name: "reality_short_id", type: "string", tab: "tls",
          ui_label: "Reality short ID",
          placeholder: "0123abcd",
          parent_enabled: "reality_enabled", advanced: true },
        { name: "reality_private_key", type: "string", tab: "tls",
          ui_label: "Reality private key (server)", secret: true,
          parent_enabled: "reality_enabled", advanced: true },
        { name: "reality_handshake_server", type: "string", tab: "tls",
          ui_label: "Reality handshake server (server)",
          placeholder: "example.com",
          parent_enabled: "reality_enabled", advanced: true },
        { name: "reality_handshake_server_port", type: "number", tab: "tls",
          ui_label: "Reality handshake server port (server)",
          default: 443,
          parent_enabled: "reality_enabled", advanced: true },
    ],

    emit_outbound: emit_outbound,
    emit_inbound:  emit_inbound,
};
