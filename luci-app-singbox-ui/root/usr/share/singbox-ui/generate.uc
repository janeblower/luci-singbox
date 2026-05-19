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
let dns_mod     = require("dns");

function get_bool(section, opt) {
	return uci.get("singbox-ui", section, opt) === "1";
}

function get_list(section, opt) {
	let all = uci.get_all("singbox-ui", section);
	return (all != null) ? (all[opt] ?? []) : [];
}

let config = {};

let dns_block = dns_mod.build_dns(uci);
if (dns_block) config.dns = dns_block;

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
