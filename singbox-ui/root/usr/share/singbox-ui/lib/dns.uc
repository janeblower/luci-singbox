// lib/dns.uc — sing-box typed DNS (1.12+): servers, rules, settings.
// Built from dns_server / dns_rule / dns UCI sections. Pure: no I/O.

let helpers       = require("helpers");
let dns_reg       = require("builder.dns.registry");        // eager-loads all 14 DNS descriptors
let dns_rule_reg  = require("builder.dns_rule.registry");   // eager-loads default/logical dns_rule descriptors
let dr_headless   = require("builder.dns_rule.headless");
let filler        = require("builder._filler");

const s_opt = helpers.s_opt;
const s_num = helpers.s_num;

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

// ruleset_enabled_map(cur) -> { name: bool } for every ruleset section.
// helpers.ruleset_active also honours the builtin master switch — see route.uc.
function ruleset_enabled_map(cur) {
	let rs_enabled = {};
	cur.foreach("singbox-ui", "ruleset", function(s) { rs_enabled[s[".name"]] = helpers.ruleset_active(cur, s); });
	return rs_enabled;
}

// build_rules(cur, srv_tags?, rs_enabled?) — descriptor-driven, mirrors
// route.uc build_route_rules: filler-built per-rule JSON + cross-cutting logic
// (logical inlining, rule_set ref resolution, dangling-server drop).
// The two maps are optional so the function stays standalone-callable
// (tests/parity); when build_dns drives it it threads the maps it already
// computed instead of re-walking the sections (GEN-4).
function build_rules(cur, srv_tags, rs_enabled) {
	if (rs_enabled == null) rs_enabled = ruleset_enabled_map(cur);
	if (srv_tags == null)   srv_tags   = enabled_server_tags(cur);

	let rules = [];
	let dr_by_name = {};
	cur.foreach("singbox-ui", "dns_rule", function(s) { dr_by_name[s[".name"]] = s; });

	let consumed = {};
	cur.foreach("singbox-ui", "dns_rule", function(s) {
		if (s.enabled === "0") return;
		if ((s.type ?? "default") !== "logical") return;
		for (let n in helpers.as_array(s.rules)) consumed[n] = true;
	});

	function resolve_rulesets(rule) {
		if (rule.rule_set == null) return;
		let resolved = [];
		for (let n in rule.rule_set) if (rs_enabled[n]) push(resolved, n);
		if (length(resolved)) rule.rule_set = resolved; else delete rule.rule_set;
	}

	cur.foreach("singbox-ui", "dns_rule", function(s) {
		if (s.enabled === "0") return;
		let t = s.type ?? "default";
		let name = s[".name"];
		if (t === "default" && consumed[name]) return;   // consumed → nested only

		let d = dns_rule_reg.get("dns_rule", t);
		if (d == null) {
			warn(sprintf("dns.uc: unknown dns_rule type '%s' for '%s'; skipping\n", t, name));
			return;
		}
		let rule = filler.build(d, s);

		if (t === "logical") {
			rule.type = "logical";
			let sub = [];
			for (let n in helpers.as_array(s.rules)) {
				let rs = dr_by_name[n];
				if (rs == null) continue;
				if ((rs.type ?? "default") === "logical") continue;   // only default refs
				if (rs.enabled === "0") continue;
				let h = dr_headless.build(rs);
				if (length(keys(h))) push(sub, h);
			}
			if (!length(sub)) return;   // empty logical → skip
			rule.rules = sub;
		}

		// S3.2: Drop a rule whose route-action server is dangling (sing-box hard-fails).
		// Checked BEFORE resolve_rulesets, which marks the sets it sees as referenced
		// (and a referenced set is emitted top-level and fetched): a rule that is
		// about to be dropped must not keep a rule-set alive. Mirrors route.uc.
		if (rule.action === "route") {
			if (!length(rule.server ?? "")) {
				warn(sprintf("dns.uc: dns_rule '%s' action=route without server; dropping\n", name));
				return;
			}
			if (!srv_tags[rule.server]) {
				warn(sprintf("dns.uc: dns_rule '%s' server '%s' is not an enabled dns_server; dropping\n", name, rule.server));
				return;
			}
		}

		resolve_rulesets(rule);
		push(rules, rule);
	});
	return rules;
}

// referenced_rulesets(dns_block) -> [name, ...]
// The deduped rule-set tags the BUILT dns rules reference. generate.uc unions
// these with route.uc's set before emitting route.rule_set definitions —
// without that, a rule-set used only by a dns_rule is named with no definition
// and sing-box refuses to start ("rule-set not found").
//
// It reads the BUILT rules, not the cursor, for the same reason inbound.uc does:
// a second walk over UCI restating build_rules' filters WILL drift, and it had.
// build_rules drops an action=route rule whose `server` is empty or points at a
// disabled dns_server BEFORE resolving its rule-sets; this walk did not, so a
// disabled dns_server left a route.rule_set that sing-box then downloaded and
// refreshed on a schedule for a rule that was not in the config at all.
// Pure: no I/O.
function referenced_rulesets(dns_block) {
	let out = [];
	let seen = {};
	for (let rule in (dns_block != null ? (dns_block.rules ?? []) : [])) {
		let refs = rule.rule_set ?? [];
		if (type(refs) === "string") refs = [ refs ];
		for (let n in refs)
			if (!seen[n]) { push(out, n); seen[n] = true; }
	}
	return out;
}

// build_dns(cur) -> object | null
function build_dns(cur) {
	let out = {};
	// GEN-4: compute the enabled-server and enabled-ruleset maps ONCE and thread
	// them into build_rules + the dns.final check, instead of each callee
	// re-walking the dns_server / ruleset sections.
	let srv_tags   = enabled_server_tags(cur);
	let rs_enabled = ruleset_enabled_map(cur);

	let servers = build_servers(cur);
	if (length(servers)) out.servers = servers;
	let rules = build_rules(cur, srv_tags, rs_enabled);
	if (length(rules)) out.rules = rules;

	let d = cur.get_all("singbox-ui", "dns");
	if (d != null) {
		// S3.2: only emit dns.final when it names an enabled dns_server; a
		// dangling final tag makes sing-box refuse to start.
		if (length(s_opt(d, "final"))) {
			if (srv_tags[d.final]) out.final = d.final;
			else warn(sprintf("dns.uc: dns.final '%s' is not an enabled dns_server; omitting\n", d.final));
		}
		if (length(s_opt(d, "strategy"))) out.strategy = d.strategy;
		if (d.independent_cache === "1")  out.independent_cache = true;
	}

	return length(keys(out)) ? out : null;
}

return { build_dns, build_rules, referenced_rulesets };
