// lib/protocols/hysteria2.uc — Hysteria2 outbound + inbound (E2 DSL).
// TLS is mandatory for hysteria2; the shared TLS block is invoked with
// force_enabled so the JSON always carries a tls{} block.

let reg = require("builder.protocols.registry");

reg.register({
    kind: "outbound", type: "hysteria2", sing_box_type: "hysteria2",
    shared: { tls: { force_enabled: true }, dial: true },

    fields: [
        { name: "server", type: "string", tab: "basic", required: true,
          validate: "host", ui_label: "Server",
          json_key: "server", omit_when: "never" },
        { name: "server_port", type: "number", tab: "basic", required: true,
          validate: "port", default: 443, ui_label: "Server port",
          json_key: "server_port", coerce: "num", omit_when: "never" },
        { name: "server_password", type: "string", tab: "basic", required: true,
          secret: true, ui_label: "Password",
          json_key: "password", omit_when: "never" },
        { name: "up_mbps", type: "number", tab: "basic", ui_label: "Uplink Mbps", placeholder: "50",
          json_key: "up_mbps", coerce: "num" },
        { name: "down_mbps", type: "number", tab: "basic", ui_label: "Downlink Mbps", placeholder: "200",
          json_key: "down_mbps", coerce: "num" },
        { name: "obfs_type", type: "enum", tab: "basic",
          values: ["", "salamander"], ui_label: "Obfs type", advanced: true },
        { name: "obfs_password", type: "string", tab: "basic",
          secret: true, ui_label: "Obfs password", advanced: true,
          parent_enabled: "obfs_type" },
        { name: "network", type: "enum", tab: "basic",
          values: ["", "tcp", "udp"], ui_label: "Network", advanced: true,
          json_key: "network", only_values: ["tcp", "udp"] },
        { name: "brutal_debug", type: "bool", tab: "basic",
          ui_label: "Brutal debug", default: 0, advanced: true,
          json_key: "brutal_debug", coerce: "bool" },
        { name: "masquerade", type: "string", tab: "basic",
          ui_label: "Masquerade URL", placeholder: "https://example.com", advanced: true,
          json_key: "masquerade" },
    ],

    groups: [
        { json_key: "obfs", gate: { all_present: ["obfs_type", "obfs_password"] },
          fields: [
              { name: "obfs_type",     json_key: "type" },
              { name: "obfs_password", json_key: "password" },
          ] },
    ],
});

reg.register({
    kind: "inbound", type: "hysteria2", sing_box_type: "hysteria2",
    shared: { tls: { force_enabled: true } },

    fields: [
        { name: "listen", type: "string", tab: "basic", default: "::",
          ui_label: "Listen address" },
        { name: "listen_port", type: "number", tab: "basic", required: true,
          validate: "port", default: 443, ui_label: "Listen port" },
        // ui_label is plain "Password" rather than "Password (single user)":
        // applyMaterialized() in descriptor_form.js dedupes shared (tab,name)
        // pairs across protocols and keeps the FIRST registered label. Both
        // shadowsocks and trojan also register (basic, server_password) with
        // ui_label "Password" and run earlier in SB_INBOUND_PROTOCOLS, so any
        // parenthetical here is silently dropped. The multi-user fallback is
        // expressed by the adjacent inbound_user list ("Users (name:password)").
        { name: "server_password", type: "string", tab: "basic", required: true,
          secret: true, ui_label: "Password" },
        { name: "inbound_user", type: "list", tab: "basic", secret: true,
          ui_label: "Users (name:password)", advanced: true },
        { name: "up_mbps", type: "number", tab: "basic", ui_label: "Uplink Mbps",
          json_key: "up_mbps", coerce: "num" },
        { name: "down_mbps", type: "number", tab: "basic", ui_label: "Downlink Mbps",
          json_key: "down_mbps", coerce: "num" },
        { name: "ignore_client_bandwidth", type: "bool", tab: "basic",
          ui_label: "Ignore client bandwidth", default: 0, advanced: true,
          json_key: "ignore_client_bandwidth", coerce: "bool" },
        { name: "obfs_type", type: "enum", tab: "basic",
          values: ["", "salamander"], ui_label: "Obfs type", advanced: true },
        { name: "obfs_password", type: "string", tab: "basic",
          secret: true, ui_label: "Obfs password", advanced: true,
          parent_enabled: "obfs_type" },
        { name: "masquerade", type: "string", tab: "basic",
          ui_label: "Masquerade URL", placeholder: "https://example.com", advanced: true,
          json_key: "masquerade" },
        { name: "brutal_debug", type: "bool", tab: "basic",
          ui_label: "Brutal debug", default: 0, advanced: true,
          json_key: "brutal_debug", coerce: "bool" },
    ],

    groups: [
        { json_key: "obfs", gate: { all_present: ["obfs_type", "obfs_password"] },
          fields: [
              { name: "obfs_type",     json_key: "type" },
              { name: "obfs_password", json_key: "password" },
          ] },
    ],

    users: {
        from: "inbound_user",
        columns: [
            { key: "name", required: true },
            { key: "password", always: true },
        ],
        single_fallback: { fields: [ { key: "password", from: "server_password" } ] },
    },
});

return {};
