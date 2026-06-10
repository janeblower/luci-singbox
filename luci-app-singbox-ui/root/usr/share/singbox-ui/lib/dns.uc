// lib/dns.uc — sing-box typed DNS (1.12+): servers, rules, settings.
// Built from dns_server / dns_rule / dns UCI sections. Pure: no I/O.

let helpers = require("helpers");
const s_opt    = helpers.s_opt;
const s_num    = helpers.s_num;
const csv_list = helpers.csv_list;

function build_servers(cur) {
	let servers = [];
	cur.foreach("singbox-ui", "dns_server", function(s) {
		if (s.enabled === "0") return;
		let t = s_opt(s, "type");
		let tag = s[".name"];
		let srv = null;
		if (t === "fakeip") {
			srv = { type: "fakeip", tag: tag };
			if (length(s_opt(s, "inet4_range"))) srv.inet4_range = s.inet4_range;
			if (length(s_opt(s, "inet6_range"))) srv.inet6_range = s.inet6_range;
		} else if (t === "udp" || t === "tls" || t === "https") {
			srv = { type: t, tag: tag, server: s_opt(s, "server") };
			if (length(s_opt(s, "server_port"))) srv.server_port = s_num(s.server_port);
			if (t === "https" && length(s_opt(s, "path"))) srv.path = s.path;
			if (length(s_opt(s, "detour"))) srv.detour = s.detour;
			if (length(s_opt(s, "domain_resolver"))) srv.domain_resolver = s.domain_resolver;
		} else {
			warn(sprintf("dns.uc: unknown dns_server type '%s' for '%s'; skipping\n", t, tag));
			return;
		}
		push(servers, srv);
	});
	return servers;
}

function build_rules(cur) {
	let rs_enabled = {};
	cur.foreach("singbox-ui", "ruleset", function(s) { rs_enabled[s[".name"]] = (s.enabled !== "0"); });

	let rules = [];
	cur.foreach("singbox-ui", "dns_rule", function(s) {
		if (s.enabled === "0") return;
		let rule = { action: "route" };

		let refs = s.ruleset ?? [];
		if (type(refs) === "string") refs = [ refs ];
		let resolved = [];
		for (let n in refs) if (rs_enabled[n]) push(resolved, n);
		if (length(resolved)) rule.rule_set = resolved;

		let dsuf = csv_list(s_opt(s, "domain_suffix"));
		if (length(dsuf)) rule.domain_suffix = dsuf;
		let dkw = csv_list(s_opt(s, "domain_keyword"));
		if (length(dkw)) rule.domain_keyword = dkw;
		if (length(s_opt(s, "clash_mode"))) rule.clash_mode = s.clash_mode;

		let server = s_opt(s, "server");
		// Drop rules with no matcher or no target.
		let has_match = rule.rule_set || rule.domain_suffix || rule.domain_keyword || rule.clash_mode;
		if (!has_match || !length(server)) return;
		rule.server = server;
		// rewrite_ttl default = 60. Empty/absent → 60. "0" → 0 (explicit
		// disable). A non-numeric value (+"abc" → NaN) also falls back to 60
		// rather than serializing to null and breaking sing-box (S4-9).
		let rtt_raw = s_opt(s, "rewrite_ttl");
		if (rtt_raw === "") {
			rule.rewrite_ttl = 60;
		} else {
			let n = +rtt_raw;
			rule.rewrite_ttl = (n == n) ? n : 60;
		}
		push(rules, rule);
	});
	return rules;
}

// build_dns(cur) -> object | null
function build_dns(cur) {
	let out = {};
	let servers = build_servers(cur);
	if (length(servers)) out.servers = servers;
	let rules = build_rules(cur);
	if (length(rules)) out.rules = rules;

	let d = cur.get_all("singbox-ui", "dns");
	if (d != null) {
		if (length(s_opt(d, "final")))    out.final = d.final;
		if (length(s_opt(d, "strategy"))) out.strategy = d.strategy;
		if (d.independent_cache === "1")  out.independent_cache = true;
	}

	return length(keys(out)) ? out : null;
}

return { build_dns, build_rules };
