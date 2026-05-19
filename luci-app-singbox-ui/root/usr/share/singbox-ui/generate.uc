#!/usr/bin/ucode
// Read UCI config and write the sing-box config JSON.
//
// Env overrides (used by tests / init.d):
//   SINGBOX_TMPDIR (default /tmp/singbox-ui) — source dir for sub_*.txt
//   SINGBOX_CONFIG (default /tmp/singbox-ui.json) — output path
//   UCI_CONFIG_DIR — honoured by require("uci").cursor

const CONFIG_OUT = getenv("SINGBOX_CONFIG") || "/tmp/singbox-ui.json";

let uci_dir = getenv("UCI_CONFIG_DIR");
let uci = uci_dir ? require("uci").cursor(uci_dir) : require("uci").cursor();
let fs  = require("fs");
let outbound_mod = require("outbound");
let route_mod   = require("route");
let ruleset_mod = require("ruleset");

function get_bool(section, opt) {
	return uci.get("singbox-ui", section, opt) === "1";
}

function get_list(section, opt) {
	let all = uci.get_all("singbox-ui", section);
	return (all != null) ? (all[opt] ?? []) : [];
}

function build_dns_rules() {
	let rules = [];
	uci.foreach("singbox-ui", "ruleset", function(section) {
		if (section.enabled === "0") return;
		if (section.dns_fakeip !== "1") return;
		let server_tag = section.dns_fakeip_tag ?? "fakeip";
		push(rules, { rule_set: [ section[".name"] ], server: server_tag });
	});
	return rules;
}

let config = {};

if (get_bool("fakeip", "enabled")) {
	let fakeip = { enabled: true };
	let v4 = uci.get("singbox-ui", "fakeip", "inet4_range");
	let v6 = uci.get("singbox-ui", "fakeip", "inet6_range");
	// Defensive: if a legacy list-form config slipped past migration, take
	// the first element. sing-box 1.12+ rejects array form here.
	if (type(v4) === "array") v4 = length(v4) ? v4[0] : null;
	if (type(v6) === "array") v6 = length(v6) ? v6[0] : null;
	if (v4) fakeip.inet4_range = v4;
	if (v6) fakeip.inet6_range = v6;
	config.dns = { fakeip: fakeip };
	let dns_rules = build_dns_rules();
	if (length(dns_rules)) config.dns.rules = dns_rules;
}

if (get_bool("tproxy", "enabled")) {
	let port = +(uci.get("singbox-ui", "tproxy", "port") ?? "7893") || 7893;
	config.inbounds = [ {
		type: "tproxy",
		listen: "::",
		listen_port: port,
	} ];
}

let outbounds = outbound_mod.build_outbounds(uci);
if (length(outbounds)) config.outbounds = outbounds;

let r     = route_mod.build_route_rules(uci);
let rsets = ruleset_mod.build_rule_sets(uci, r.referenced);
if (length(rsets) || length(r.rules) || r.final) {
	config.route = {};
	if (length(rsets))   config.route.rule_set = rsets;
	if (length(r.rules)) config.route.rules    = r.rules;
	if (r.final && r.final !== "direct") config.route.final = r.final;
}

let f = fs.open(CONFIG_OUT, "w");
if (!f) {
	warn(`generate.uc: cannot open ${CONFIG_OUT} for writing\n`);
	exit(1);
}
f.write(sprintf("%.4J\n", config));
f.close();

print("OK\n");
