// lib/builder/route/ruleset_local.uc — rule_set:local.
let reg = require("builder.protocols.registry");
reg.register({
    kind: "rule_set", type: "local", sing_box_type: "local",
    fields: [
        { name: "path", type: "string", tab: "basic", required: true,
          json_key: "path", omit_when: "never",
          placeholder: "/etc/singbox-ui/rules/cn.json", ui_label: "Path" },
        { name: "format", type: "enum", tab: "basic",
          values: [ "", "source", "binary" ], ui_label: "Format" },
        { name: "nft_rules", type: "bool", tab: "basic", ui_label: "Create nftables rules" },
    ],
});
return {};
