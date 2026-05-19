// lib/route.uc — sing-box `route.rules` and final outbound; reports referenced rulesets.

let helpers = require("helpers");

// build_route_rules(cur) -> { rules, final, referenced }
//   rules:      array of route.rule objects (rule_set / inbound / ... matched to outbound)
//   final:      string tag of the final outbound, or null
//   referenced: array of (deduped) ruleset names actually referenced by enabled route_rules,
//               filtered to those whose ruleset section is enabled.
function build_route_rules(cur) {
	let rules = [];
	let referenced = [];
	let seen = {};

	if (helpers.get_bool(cur, "tproxy", "hijack_dns"))
		push(rules, { protocol: "dns", action: "hijack-dns" });

	// Build a quick name→enabled lookup for rulesets. Disabled rulesets are
	// dropped from each route_rule's `rule_set` list; if that empties the
	// list, the route_rule itself is skipped (matches original behavior).
	let rs_enabled = {};
	cur.foreach("singbox-ui", "ruleset", function(s) {
		rs_enabled[s[".name"]] = (s.enabled !== "0");
	});

	cur.foreach("singbox-ui", "route_rule", function(section) {
		if (section.enabled === "0") return;

		let refs = section.ruleset ?? [];
		if (type(refs) === "string") refs = [ refs ];

		let resolved = [];
		for (let rs_name in refs) {
			if (!rs_enabled[rs_name]) continue;   // missing or disabled
			if (!seen[rs_name]) { push(referenced, rs_name); seen[rs_name] = true; }
			push(resolved, rs_name);
		}
		if (!length(resolved)) return;

		let action = section.action ?? "direct";
		let target;
		if (action === "direct")        target = "direct";
		else if (action === "block")    target = "block";
		else if (action === "outbound") target = section.outbound;
		if (!target) return;

		push(rules, { rule_set: resolved, outbound: target });
	});

	let final = null;
	let rd = cur.get_all("singbox-ui", "route_default");
	if (rd) {
		let action = rd.action ?? "direct";
		if (action === "direct")        final = "direct";
		else if (action === "block")    final = "block";
		else if (action === "outbound") final = rd.outbound ?? null;
	}

	return { rules, final, referenced };
}

return { build_route_rules };
