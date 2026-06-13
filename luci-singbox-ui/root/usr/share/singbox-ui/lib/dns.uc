// lib/dns.uc — sing-box typed DNS (1.12+): servers, rules, settings.
// Built from dns_server / dns_rule / dns UCI sections. Pure: no I/O.

let helpers  = require("helpers");
let dns_reg  = require("builder.dns.registry");   // eager-loads all 14 DNS descriptors
let filler   = require("builder._filler");

const s_opt    = helpers.s_opt;
const s_num    = helpers.s_num;
const csv_list = helpers.csv_list;

// enabled_server_tags(cur) -> { tag: true } for every enabled dns_server.
// Used to drop dns_rule.server / dns.final references that don't resolve to an
// enabled server — sing-box hard-fails on a dangling server tag, the same way
// it does on a dangling rule_set (which we already filter). See S3.2.
function enabled_server_tags(cur) {
	let tags = {};
	cur.foreach("singbox-ui", "dns_server", function(s) {
		if (s.enabled === "0") return;
		tags[s[".name"]] = true;
	});
	return tags;
}

function build_servers(cur) {
	let servers = [];
	cur.foreach("singbox-ui", "dns_server", function(s) {
		if (s.enabled === "0") return;
		let t = s_opt(s, "type");
		let d = dns_reg.get("dns", t);
		if (d == null) {
			warn(sprintf("dns.uc: unknown dns_server type '%s' for '%s'; skipping\n", t, s[".name"]));
			return;
		}
		let srv = (type(d.emit) === "function") ? d.emit(s) : filler.build(d, s);
		if (srv != null) push(servers, srv);
	});
	return servers;
}

function build_rules(cur) {
	let rs_enabled = {};
	cur.foreach("singbox-ui", "ruleset", function(s) { rs_enabled[s[".name"]] = (s.enabled !== "0"); });
	let srv_tags = enabled_server_tags(cur);

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
		// S3.2: drop the rule if its server tag doesn't resolve to an enabled
		// dns_server — a dangling server reference makes sing-box refuse to start.
		if (!srv_tags[server]) {
			warn(sprintf("dns.uc: dns_rule '%s' server '%s' is not an enabled dns_server; dropping rule\n", s[".name"], server));
			return;
		}
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

// referenced_rulesets(cur) -> [name, ...]
// The deduped set of enabled rulesets referenced by enabled dns_rule sections.
// Mirrors the ref-resolution in build_rules (same enabled/existence filter), so
// generate.uc can UNION these with route.uc's referenced set before building
// route.rule_set definitions. Without this, a ruleset referenced only by a
// dns_rule is emitted as a dns.rules[].rule_set tag with no matching
// route.rule_set definition, and sing-box refuses to start ("rule-set not
// found"). Pure: no I/O. See S3.1.
function referenced_rulesets(cur) {
	let rs_enabled = {};
	cur.foreach("singbox-ui", "ruleset", function(s) { rs_enabled[s[".name"]] = (s.enabled !== "0"); });

	let out = [];
	let seen = {};
	cur.foreach("singbox-ui", "dns_rule", function(s) {
		if (s.enabled === "0") return;
		let refs = s.ruleset ?? [];
		if (type(refs) === "string") refs = [ refs ];
		for (let n in refs)
			if (rs_enabled[n] && !seen[n]) { push(out, n); seen[n] = true; }
	});
	return out;
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
		// S3.2: only emit dns.final when it names an enabled dns_server; a
		// dangling final tag makes sing-box refuse to start.
		if (length(s_opt(d, "final"))) {
			let srv_tags = enabled_server_tags(cur);
			if (srv_tags[d.final]) out.final = d.final;
			else warn(sprintf("dns.uc: dns.final '%s' is not an enabled dns_server; omitting\n", d.final));
		}
		if (length(s_opt(d, "strategy"))) out.strategy = d.strategy;
		if (d.independent_cache === "1")  out.independent_cache = true;
	}

	return length(keys(out)) ? out : null;
}

return { build_dns, build_rules, referenced_rulesets };
