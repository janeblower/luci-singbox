// lib/route.uc — sing-box `route.rules` and final outbound; reports referenced rulesets.

// build_route_rules(cur) -> { rules, final, referenced }
//   rules:      array of route.rule objects (rule_set / inbound / ... matched to outbound)
//   final:      string tag of the final outbound, or null
//   referenced: array of (deduped) ruleset names actually referenced by enabled route_rules,
//               filtered to those whose ruleset section is enabled.
function build_route_rules(cur) {
	let rules = [];
	let referenced = [];
	let seen = {};

	// hijack-dns is requested by any enabled tproxy inbound with hijack_dns=1.
	let hijack = false;
	cur.foreach("singbox-ui", "inbound", function(s) {
		if (s.enabled === "0") return;
		if (s.protocol === "tproxy" && s.hijack_dns === "1") hijack = true;
	});
	if (hijack)
		push(rules, { protocol: "dns", action: "hijack-dns" });

	// Auto-emit hijack-dns rules for direct inbounds flagged as DNS listeners.
	// Must precede user-defined rules so DNS gets dispatched before any
	// other matching logic sees the connection.
	cur.foreach("singbox-ui", "inbound", function(s) {
		if (s.enabled === "0") return;
		if (s.protocol !== "direct") return;
		if (s.dns_listener !== "1") return;
		push(rules, { inbound: s[".name"], action: "hijack-dns" });
	});

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
		// sing-box 1.11+ removed the `block` outbound; the replacement is a
		// rule with `action: "reject"` (no outbound). Direct/outbound rules
		// get the explicit `action: "route"` that sing-box 1.14 will require
		// (1.12 already warns when it's missing on dial fields).
		if (action === "block") {
			push(rules, { action: "reject", rule_set: resolved });
			return;
		}
		let target;
		if (action === "direct")        target = "direct";
		else if (action === "outbound") target = section.outbound;
		if (!target) return;

		push(rules, { action: "route", rule_set: resolved, outbound: target });
	});

	let final = null;
	let rd = cur.get_all("singbox-ui", "route_default");
	if (rd) {
		let action = rd.action ?? "direct";
		if (action === "direct")        final = "direct";
		else if (action === "outbound") final = rd.outbound ?? null;
		else if (action === "block") {
			// No "block" outbound exists in sing-box 1.11+. Express
			// "block by default" as a trailing catch-all reject rule and
			// leave `final` unset (sing-box defaults the final to direct
			// when omitted; this catch-all fires first for any flow that
			// reached the end of the chain unmatched).
			push(rules, { action: "reject" });
		}
	}

	return { rules, final, referenced };
}

return { build_route_rules };
