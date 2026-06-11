// lib/ruleset.uc — sing-box `route.rule_set` definitions for referenced rule-sets.

let helpers = require("helpers");

function detect_format(rs) {
	let src = (rs.type === "local") ? (rs.path ?? "") : (rs.url ?? "");
	return helpers.detect_rs_format(src, rs.format);
}

// build_rule_sets(cur, referenced_names) — returns [{tag, type, format, url|path}, ...].
// referenced_names is the set of enabled rulesets referenced by enabled route_rules
// (computed by route.uc). Disabled rulesets are filtered here for safety.
function build_rule_sets(cur, referenced_names) {
	let rule_sets = [];
	let by_name = {};
	cur.foreach("singbox-ui", "ruleset", function(s) { by_name[s[".name"]] = s; });

	for (let name in referenced_names) {
		let rs = by_name[name];
		if (!rs) continue;
		if (rs.enabled === "0") continue;
		let entry = { tag: name, type: rs.type ?? "remote", format: detect_format(rs) };
		if (entry.type === "remote") {
			if (rs.url) entry.url = rs.url;
			// Per-ruleset auto-update: hand sing-box `update_interval` so it
			// refreshes the rule-set itself — independent of "Create nftables
			// rules" (nft_rules). The app-side fetch (subscription.uc) only
			// runs for nft_rules=1; without this, a routing-only rule-set with
			// an update interval set in the UI would never auto-update. The UI
			// stores whole seconds; sing-box wants a duration string ("<n>s").
			let iv = +(rs.update_interval ?? "0");
			if (iv > 0) entry.update_interval = `${int(iv)}s`;
		} else if (entry.type === "local") {
			if (rs.path) entry.path = rs.path;
		}
		push(rule_sets, entry);
	}
	return rule_sets;
}

return { build_rule_sets };
