// lib/builder/route/ruleset_remote.uc — rule_set:remote. The sing-box `format`
// key is auto-detected from the URL extension in ruleset.uc (.srs→binary,
// .json→source) — no UI field. update_interval is post-processed there ("<n>s");
// nft_rules is consumed outside the rule_set JSON. Both are UI-only (no json_key).
// download_detour picks an existing outbound to fetch the rule-set through (e.g.
// so the download survives a censored direct path). The field is deprecated in
// sing-box and slated for removal in 1.16, but works on all versions we target
// (1.12+), so it is NOT version-gated.
let reg = require("builder.protocols.registry");
reg.register({
    kind: "rule_set", type: "remote", sing_box_type: "remote",
    fields: [
        { name: "url", type: "string", tab: "basic", required: true,
          json_key: "url", omit_when: "never", placeholder: "https://example.com/geosite.srs",
          ui_label: "URL" },
        { name: "update_interval", type: "string", tab: "basic",
          placeholder: "86400", ui_label: "Update interval (s)" },
        { name: "download_detour", type: "string", tab: "basic", dynamic: "outbounds",
          json_key: "download_detour", ui_label: "Download detour" },
        { name: "nft_rules", type: "bool", tab: "basic", ui_label: "Create nftables rules" },
    ],
});
return {};
