// lib/builder/route/ruleset_inline.uc — rule_set:inline. `rules` references
// default route_rule sections; ruleset.uc inlines them as headless. UI-only.
let reg = require("builder.protocols.registry");
reg.register({
    kind: "rule_set", type: "inline", sing_box_type: "inline",
    fields: [
        { name: "rules", type: "list", tab: "basic", dynamic: "route_rules",
          ui_label: "Headless rules" },
        { name: "nft_rules", type: "bool", tab: "basic", ui_label: "Create nftables rules" },
    ],
});
return {};
