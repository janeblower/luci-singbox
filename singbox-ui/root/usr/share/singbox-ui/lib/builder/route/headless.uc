// lib/builder/route/headless.uc — build a headless (matchers-only) rule object
// from a default route_rule section. Used by route.uc (logical inlining) and
// ruleset.uc (inline rule-sets). No type/tag, no action.
let filler = require("builder._filler");
let match  = require("builder._shared.match");
const HEADLESS_DESC = { kind: "route_rule", sing_box_type: "", fields: match.fields("headless") };
function build(section) { return filler.build(HEADLESS_DESC, section); }
return { build };
