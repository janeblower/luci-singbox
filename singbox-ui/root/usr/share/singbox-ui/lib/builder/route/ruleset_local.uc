// lib/builder/route/ruleset_local.uc — rule_set:local. `format` is not a UI
// field: sing-box needs it, but it is derivable from the path's extension
// (.srs→binary, .json→source), so post() computes it and `derived_keys` tells
// _unfiller to consume — not re-store — it. See ruleset_remote.uc.
let reg     = require("builder.protocols.registry");
let helpers = require("helpers");

reg.register({
    kind: "rule_set", type: "local", sing_box_type: "local",
    derived_keys: [ "format" ],
    fields: [
        { name: "path", type: "string", tab: "basic", required: true,
          json_key: "path", omit_when: "never",
          placeholder: "/etc/singbox-ui/rules/cn.json", ui_label: "Path" },
        { name: "nft_rules", type: "bool", tab: "basic", ui_label: "Create nftables rules" },
    ],
    post: function(out, s) {
        out.format = helpers.detect_rs_format(s.path ?? "");
    },
});
return {};
