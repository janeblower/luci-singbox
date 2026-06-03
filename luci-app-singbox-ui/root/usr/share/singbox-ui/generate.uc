#!/usr/bin/ucode
// generate.uc — read UCI and emit the sing-box config JSON. Orchestration only;
// all section builders live in /usr/share/singbox-ui/lib/*.uc and are loaded
// via `-L` (set by the init.d, rpcd, and cron wrappers).
//
// Env overrides (tests/init.d):
//   SINGBOX_TMPDIR (default /tmp/singbox-ui)  — consumed by lib/outbound.uc
//   SINGBOX_CONFIG (default /tmp/singbox-ui.json) — output path
//   UCI_CONFIG_DIR — honoured by require("uci").cursor

const CONFIG_OUT = getenv("SINGBOX_CONFIG") || "/tmp/singbox-ui.json";

let uci_dir = getenv("UCI_CONFIG_DIR");
let uci = uci_dir ? require("uci").cursor(uci_dir) : require("uci").cursor();
let fs  = require("fs");

let log_mod      = require("log");
let dns_mod      = require("dns");
let inbound_mod  = require("inbound");
let outbound_mod = require("outbound");
let route_mod    = require("route");
let ruleset_mod  = require("ruleset");
let cache_mod    = require("cache");
let clash_mod    = require("clash");

let config = {};

let log_block = log_mod.build_log(uci);
if (log_block) config.log = log_block;

let dns_block = dns_mod.build_dns(uci);
if (dns_block) config.dns = dns_block;

let in_block = inbound_mod.build_inbounds(uci);
if (length(in_block)) config.inbounds = in_block;

let out_block = outbound_mod.build_outbounds(uci);

// route.rules / route_default / dns.detour reference outbound TAGS — sing-box
// 1.11+ no longer provides an implicit `direct` outbound, so inject one when
// the user hasn't defined their own. The `block` outbound was removed in 1.11;
// route.uc emits `action: "reject"` rules instead, so nothing to inject here.
let have_direct = false;
for (let o in out_block) {
	if (o.tag === "direct") have_direct = true;
}
// The auto-injected direct is field-less. sing-box 1.12 fatally rejects a
// dns_server `detour` pointing at it ("detour to an empty direct outbound
// makes no sense"); the scrub below drops such references.
let implicit_empty = {};
if (!have_direct) { implicit_empty["direct"] = true; push(out_block, { tag: "direct", type: "direct" }); }

config.outbounds = out_block;

if (config.dns && type(config.dns.servers) === "array") {
	for (let s in config.dns.servers) {
		if (s.detour != null && implicit_empty[s.detour]) {
			warn(sprintf("generate.uc: dropping dns_server[%s].detour='%s' (would reference an empty implicit outbound)\n",
				s.tag ?? "?", s.detour));
			delete s.detour;
		}
	}
}

let r = route_mod.build_route_rules(uci);
let rsets = ruleset_mod.build_rule_sets(uci, r.referenced);
if (length(rsets) || length(r.rules) || r.final) {
	config.route = {};
	if (length(rsets))   config.route.rule_set = rsets;
	if (length(r.rules)) config.route.rules    = r.rules;
	if (r.final)         config.route.final    = r.final;
}

// sing-box 1.12 warns "missing route.default_domain_resolver ... will be
// removed in sing-box 1.14". Resolve here: honour an explicit UCI
// `dns.default_resolver` tag if present; otherwise auto-pick the first
// enabled non-fakeip dns_server. Skipped if no resolver candidate exists.
if (config.route && type(config.dns) === "object" && type(config.dns.servers) === "array") {
	let dns_section = uci.get_all("singbox-ui", "dns");
	let resolver_tag = dns_section ? dns_section.default_resolver : null;
	if (resolver_tag == null || resolver_tag === "") {
		for (let s in config.dns.servers) {
			if (s.type !== "fakeip" && length(s.tag)) { resolver_tag = s.tag; break; }
		}
	}
	if (resolver_tag != null && length(resolver_tag))
		config.route.default_domain_resolver = { server: resolver_tag };
}

let experimental = {};
let cache_block = cache_mod.build_cache(uci);
if (cache_block) experimental.cache_file = cache_block;
let clash_block = clash_mod.build_clash_api(uci);
if (clash_block) experimental.clash_api = clash_block;
if (length(keys(experimental))) config.experimental = experimental;

let f = fs.open(CONFIG_OUT, "w");
if (!f) {
	warn(`generate.uc: cannot open ${CONFIG_OUT} for writing\n`);
	exit(1);
}
f.write(sprintf("%.4J\n", config));
f.close();

print("OK\n");
