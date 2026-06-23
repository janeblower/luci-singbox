// lib/builder/settings/clash_api.uc — sing-box experimental.clash_api (singleton).
// `enabled`/`listen`/`port` are UI-only (no json_key); post() composes
// external_controller with IPv6-bracket handling (RFC 3986 §3.2.2).
// All other fields are direct json_key mapped.
let reg = require("builder.protocols.registry");
reg.register({
    kind: "clash_api", type: "clash_api", sing_box_type: "clash_api",
    fields: [
        { name: "enabled", type: "bool", tab: "basic",
          ui_label: "Enable" },
        { name: "listen", type: "string", tab: "basic", default: "127.0.0.1",
          parent_enabled: "enabled",
          ui_label: "Listen address" },
        { name: "port", type: "string", tab: "basic", default: "9090",
          validate: "port", parent_enabled: "enabled",
          ui_label: "Port" },
        { name: "secret", type: "string", tab: "basic", secret: true,
          json_key: "secret", parent_enabled: "enabled",
          ui_label: "API secret",
          ui_help: "Bearer token for the Clash API. Leave empty for no auth." },
        { name: "external_ui", type: "string", tab: "basic", advanced: true,
          json_key: "external_ui", parent_enabled: "enabled",
          ui_label: "External UI directory" },
        { name: "external_ui_download_url", type: "string", tab: "basic", advanced: true,
          json_key: "external_ui_download_url", parent_enabled: "enabled",
          ui_label: "External UI download URL" },
        { name: "external_ui_download_detour", type: "string", tab: "basic", advanced: true,
          json_key: "external_ui_download_detour", parent_enabled: "enabled",
          dynamic: "outbounds",
          ui_label: "External UI download detour" },
        { name: "default_mode", type: "enum", tab: "basic", advanced: true,
          json_key: "default_mode", parent_enabled: "enabled",
          values: [ "", "rule", "global", "direct" ],
          ui_label: "Default mode" },
        { name: "access_control_allow_origin", type: "list", tab: "basic", advanced: true,
          json_key: "access_control_allow_origin", parent_enabled: "enabled",
          coerce: "array",
          ui_label: "Access-Control-Allow-Origin" },
        { name: "access_control_allow_private_network", type: "bool", tab: "basic", advanced: true,
          json_key: "access_control_allow_private_network", parent_enabled: "enabled",
          coerce: "bool",
          ui_label: "Allow private network" },
    ],
    post: function(out, s) {
        let listen = (s.listen != null && length(s.listen)) ? s.listen : "127.0.0.1";
        let port   = (s.port   != null && length(s.port))   ? s.port   : "9090";
        // Strip any brackets the user already typed ("[::1]" -> "::1") so we
        // never double-bracket, then re-bracket IPv6 literals (any ':' in host).
        let host = replace(replace(listen, /^\[/, ""), /\]$/, "");
        out.external_controller = (index(host, ":") >= 0)
            ? sprintf("[%s]:%s", host, port)
            : `${host}:${port}`;
        // SECURITY (warn-only): a non-loopback external_controller with no secret
        // exposes an UNAUTHENTICATED control API (mutates proxy selection, reads
        // traffic stats) to the network. We still honor the explicit bind, but
        // surface a warning so the operator sets a secret.
        let is_loopback = (host == "127.0.0.1" || host == "::1" || host == "localhost" ||
                           substr(host, 0, 4) == "127.");
        if (!is_loopback && !length(s.secret ?? "")) {
            warn(sprintf("clash.uc: clash_api binds non-loopback '%s' with an empty secret — the control API is UNAUTHENTICATED and reachable from the network; set a secret\n", host));
        }
    },
});
return {};
