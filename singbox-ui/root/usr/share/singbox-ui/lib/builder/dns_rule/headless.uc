// lib/builder/dns_rule/headless.uc — matchers-only object for dns logical
// sub-rules. No type/tag, no action, no top-level-only matchers (rule_set/
// inbound/auth_user/clash_mode excluded by the dns_headless ctx).
let filler = require("builder._filler");
let match  = require("builder._shared.match");
const HEADLESS_DESC = { kind: "dns_rule", sing_box_type: "", fields: match.fields("dns_headless") };
function build(section) { return filler.build(HEADLESS_DESC, section); }
return { build };
