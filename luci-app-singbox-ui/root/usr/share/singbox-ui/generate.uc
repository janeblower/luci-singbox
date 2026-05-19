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

function get_bool(section, opt) {
	return uci.get("singbox-ui", section, opt) === "1";
}

function get_list(section, opt) {
	let all = uci.get_all("singbox-ui", section);
	return (all != null) ? (all[opt] ?? []) : [];
}

// Pick the sing-box rule-set format. Honour UCI `format` if set (legacy
// configs); otherwise infer from the file extension of url/path.
function detect_format(rs) {
	if (rs.format) return rs.format;
	let src = (rs.type === "local") ? (rs.path ?? "") : (rs.url ?? "");
	if (match(src, /\.srs$/i))  return "binary";
	if (match(src, /\.json$/i)) return "source";
	return "binary";
}

function build_route_config() {
	let rules = [];
	let rule_sets = [];
	let seen = {};

	let rs_by_name = {};
	uci.foreach("singbox-ui", "ruleset", function(section) {
		rs_by_name[section[".name"]] = section;
	});

	uci.foreach("singbox-ui", "route_rule", function(section) {
		if (section.enabled === "0") return;

		let refs = section.ruleset ?? [];
		if (type(refs) === "string") refs = [ refs ];

		let resolved = [];
		for (let rs_name in refs) {
			let rs = rs_by_name[rs_name];
			if (!rs) continue;
			if (rs.enabled === "0") continue;

			if (!seen[rs_name]) {
				let entry = {
					tag: rs_name,
					type: rs.type ?? "remote",
					format: detect_format(rs),
				};
				if (entry.type === "remote") {
					if (rs.url) entry.url = rs.url;
				} else if (entry.type === "local") {
					if (rs.path) entry.path = rs.path;
				}
				push(rule_sets, entry);
				seen[rs_name] = true;
			}
			push(resolved, rs_name);
		}

		if (!length(resolved)) return;

		let action = section.action ?? "direct";
		let target;
		if (action === "direct")        target = "direct";
		else if (action === "block")    target = "block";
		else if (action === "outbound") target = section.outbound;
		if (!target) return;

		push(rules, { rule_set: resolved, outbound: target });
	});

	// Final/default route (optional).
	let final_target = null;
	let rd = uci.get_all("singbox-ui", "route_default");
	if (rd) {
		let action = rd.action ?? "direct";
		if (action === "direct")        final_target = "direct";
		else if (action === "block")    final_target = "block";
		else if (action === "outbound") final_target = rd.outbound ?? null;
	}

	return { rules, rule_sets, final: final_target };
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

let route = build_route_config();
if (length(route.rules) || route.final) {
	config.route = {};
	if (length(route.rules))     config.route.rules     = route.rules;
	if (length(route.rule_sets)) config.route.rule_set  = route.rule_sets;
	if (route.final && route.final !== "direct")
		config.route.final = route.final;
}

let f = fs.open(CONFIG_OUT, "w");
if (!f) {
	warn(`generate.uc: cannot open ${CONFIG_OUT} for writing\n`);
	exit(1);
}
f.write(sprintf("%.4J\n", config));
f.close();

print("OK\n");
