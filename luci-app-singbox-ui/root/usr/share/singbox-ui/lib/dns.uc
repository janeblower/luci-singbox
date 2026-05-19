// lib/dns.uc — sing-box `dns` config: fakeip, dns rules. (Outbound DNS server added in Phase 2.)

let helpers = require("helpers");

// build_dns_rules(cur) — rulesets with dns_fakeip=1 produce DNS routing entries.
function build_dns_rules(cur) {
	let rules = [];
	cur.foreach("singbox-ui", "ruleset", function(section) {
		if (section.enabled === "0") return;
		if (section.dns_fakeip !== "1") return;
		let server_tag = section.dns_fakeip_tag ?? "fakeip";
		push(rules, { rule_set: [ section[".name"] ], server: server_tag });
	});
	return rules;
}

// build_dns(cur) -> object | null
function build_dns(cur) {
	let out = {};

	if (helpers.get_bool(cur, "fakeip", "enabled")) {
		let fakeip = { enabled: true };
		let v4 = cur.get("singbox-ui", "fakeip", "inet4_range");
		let v6 = cur.get("singbox-ui", "fakeip", "inet6_range");
		// Defensive: legacy list-form configs may slip past migration. sing-box
		// 1.12+ rejects array form here; collapse to first element.
		if (type(v4) === "array") v4 = length(v4) ? v4[0] : null;
		if (type(v6) === "array") v6 = length(v6) ? v6[0] : null;
		if (v4) fakeip.inet4_range = v4;
		if (v6) fakeip.inet6_range = v6;
		out.fakeip = fakeip;
	}

	let rules = build_dns_rules(cur);
	if (length(rules)) out.rules = rules;

	return length(keys(out)) ? out : null;
}

return { build_dns };
