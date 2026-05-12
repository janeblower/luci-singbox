#!/usr/bin/ucode
// Read UCI config and write /tmp/singbox-ui.json for sing-box.

let uci_dir = getenv("UCI_CONFIG_DIR");
let uci = uci_dir ? require("uci").cursor(uci_dir) : require("uci").cursor();
let fs  = require("fs");

function get_bool(section, opt) {
	return uci.get("singbox-ui", section, opt) === "1";
}

function get_list(section, opt) {
	let all = uci.get_all("singbox-ui", section);
	return (all != null) ? (all[opt] ?? []) : [];
}

// Produce indented JSON (4-space indent).
function indent_of(depth) {
	let s = "";
	for (let i = 0; i < depth; i++) s += "    ";
	return s;
}

function to_json(val, depth) {
	if (depth == null) depth = 0;
	let t = type(val);

	if (t === "object") {
		let ks = keys(val);
		if (!length(ks)) return "{}";
		let inner = indent_of(depth + 1);
		let outer = indent_of(depth);
		let parts = [];
		for (let k in ks)
			push(parts, inner + sprintf("%J", k) + ": " + to_json(val[k], depth + 1));
		return "{\n" + join(",\n", parts) + "\n" + outer + "}";
	}

	if (t === "array") {
		if (!length(val)) return "[]";
		let inner = indent_of(depth + 1);
		let outer = indent_of(depth);
		let parts = [];
		for (let v in val)
			push(parts, inner + to_json(v, depth + 1));
		return "[\n" + join(",\n", parts) + "\n" + outer + "]";
	}

	// Primitives: string, int, double, bool, null — %J handles all of them.
	return sprintf("%J", val);
}

function build_outbounds_and_routes() {
	let outbounds = [];
	let route_rules = [];
	let route_rule_sets = [];

	uci.foreach("singbox-ui", "outbound", function(section) {
		let name = section[".name"];
		let action = section.action;
		let outbound = null;

		if (action === "direct") {
			outbound = { tag: name, type: "direct" };
		} else if (action === "block") {
			outbound = { tag: name, type: "block" };
		} else if (action === "proxy") {
			let proxy_type = section.proxy_type;
			if (proxy_type === "interface") {
				outbound = { tag: name, type: "direct", bind_interface: section.interface };
			} else if (proxy_type === "url") {
				// URL parsing added in next task; skip for now
				warn("generate.uc: proxy url not yet supported for section: " + name + "\n");
			}
		}

		if (outbound) push(outbounds, outbound);
	});

	return { outbounds, route_rules, route_rule_sets };
}

let config = {};

if (get_bool("fakeip", "enabled")) {
	config.dns = {
		fakeip: {
			enabled: true,
			inet4_range: get_list("fakeip", "inet4_range"),
			inet6_range: get_list("fakeip", "inet6_range"),
		},
	};
}

if (get_bool("tproxy", "enabled")) {
	let port = +(uci.get("singbox-ui", "tproxy", "port") ?? "7893") || 7893;
	config.inbounds = [ {
		type: "tproxy",
		listen: "::",
		listen_port: port,
	} ];
}

let result = build_outbounds_and_routes();
let outbounds = result.outbounds;
let route_rules = result.route_rules;
let route_rule_sets = result.route_rule_sets;

if (length(outbounds)) config.outbounds = outbounds;
if (length(route_rules)) {
	config.route = { rules: route_rules };
	if (length(route_rule_sets)) config.route.rule_set = route_rule_sets;
}

let f = fs.open("/tmp/singbox-ui.json", "w");
if (!f) {
	warn("generate.uc: cannot open /tmp/singbox-ui.json for writing\n");
	exit(1);
}
f.write(to_json(config) + "\n");
f.close();

print("OK\n");
