// lib/builder/route/ruleset_remote.uc — rule_set:remote. format + update_interval
// are post-processed in ruleset.uc (auto-detect / "<n>s"); nft_rules is consumed
// outside the rule_set JSON. Those three are UI-only (no json_key).
let reg = require("builder.protocols.registry");
reg.register({
    kind: "rule_set", type: "remote", sing_box_type: "remote",
    fields: [
        { name: "url", type: "string", tab: "basic", required: true,
          json_key: "url", omit_when: "never", placeholder: "https://example.com/geosite.srs",
          ui_label: "URL" },
        { name: "format", type: "enum", tab: "basic",
          values: [ "", "source", "binary" ], ui_label: "Format" },
        { name: "update_interval", type: "string", tab: "basic",
          placeholder: "86400", ui_label: "Update interval (s)" },
        { name: "download_detour", type: "string", tab: "basic", dynamic: "outbounds",
          json_key: "download_detour", min_version: "1.14", ui_label: "Download detour" },
        { name: "nft_rules", type: "bool", tab: "basic", ui_label: "Create nftables rules" },
    ],
});
return {};
