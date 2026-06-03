// lib/dns.uc — sing-box typed DNS (1.12+): servers, rules, settings.
// Built from dns_server / dns_rule / dns UCI sections. Pure: no I/O.

function s_opt(s, k) { let v = s[k]; return (v == null) ? "" : v; }
function s_num(v) { let n = +v; return n || 0; }
function csv_list(v) {
	if (v == null || v === "") return [];
	let out = [];
	for (let p in split(v, ",")) { let t = trim(p); if (length(t)) push(out, t); }
	return out;
}

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
		// rewrite_ttl default = 60. Empty/absent → 60. "0" → 0 (explicit disable).
		let rtt_raw = s_opt(s, "rewrite_ttl");
		rule.rewrite_ttl = (rtt_raw === "") ? 60 : (+rtt_raw);
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

return { build_dns };
