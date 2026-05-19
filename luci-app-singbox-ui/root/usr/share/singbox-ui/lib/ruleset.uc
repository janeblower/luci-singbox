// lib/ruleset.uc — sing-box `route.rule_set` definitions for referenced rule-sets.

function detect_format(rs) {
	if (rs.format) return rs.format;
	let src = (rs.type === "local") ? (rs.path ?? "") : (rs.url ?? "");
	if (match(src, /\.srs$/i))  return "binary";
	if (match(src, /\.json$/i)) return "source";
	return "binary";
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
		} else if (entry.type === "local") {
			if (rs.path) entry.path = rs.path;
		}
		push(rule_sets, entry);
	}
	return rule_sets;
}

return { build_rule_sets };
