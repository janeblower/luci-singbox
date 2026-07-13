// lib/builder/route/ruleset_remote.uc — rule_set:remote.
//
// `format` is not a UI field: sing-box needs it, but it is derivable from the
// source's extension (.srs→binary, .json→source), so post() computes it and
// `derived_keys` tells _unfiller to consume — not re-store — it. It used to be
// bolted on in ruleset.uc AFTER the filler had run, which meant the JSON editor
// exported a rule-set object the generated config did not actually match.
//
// `update_interval` is stored as plain seconds and emitted as a sing-box duration
// ("86400s") — declaratively, via coerce:"duration", for the same reason: a
// conversion buried in a builder cannot be inverted, and the editor has to be able
// to turn "86400s" back into "86400".
//
// nft_rules is consumed outside the rule_set JSON (no json_key).
// download_detour picks an existing outbound to fetch the rule-set through (e.g.
// so the download survives a censored direct path). The field is deprecated in
// sing-box and slated for removal in 1.16, but works on all versions we target
// (1.12+), so it is NOT version-gated.
let reg     = require("builder.protocols.registry");
let helpers = require("helpers");

reg.register({
    kind: "rule_set", type: "remote", sing_box_type: "remote",
    derived_keys: [ "format" ],
    fields: [
        { name: "url", type: "string", tab: "basic", required: true,
          json_key: "url", omit_when: "never", placeholder: "https://example.com/geosite.srs",
          ui_label: "URL" },
        { name: "update_interval", type: "string", tab: "basic",
          json_key: "update_interval", coerce: "duration",
          placeholder: "86400", ui_label: "Update interval (s)" },
        { name: "download_detour", type: "string", tab: "basic", dynamic: "outbounds",
          json_key: "download_detour", ui_label: "Download detour" },
        { name: "nft_rules", type: "bool", tab: "basic", ui_label: "Create nftables rules" },
    ],
    post: function(out, s) {
        out.format = helpers.detect_rs_format(s.url ?? "");
    },
});
return {};
