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

function parse_query(query_string) {
	let params = {};
	for (let part in split(query_string, "&")) {
		let eq = index(part, "=");
		if (eq < 0) continue;
		let k = substr(part, 0, eq);
		let v = substr(part, eq + 1);
		params[k] = v;
	}
	return params;
}

function parse_vless(url) {
	// vless://uuid@host:port?params
	let m = match(url, /^vless:\/\/([^@]+)@([^:/?#]+):([0-9]+)(\?[^#]*)?/);
	if (!m) return null;
	let uuid = m[1];
	let host = m[2];
	let port = +m[3];
	let params = m[4] ? parse_query(substr(m[4], 1)) : {};

	let out = {
		type: "vless",
		server: host,
		server_port: port,
		uuid: uuid,
	};

	let security = params["security"];
	if (security === "tls" || security === "reality") {
		let sni = params["sni"] ?? host;
		out.tls = { enabled: true, server_name: sni };
		if (params["fp"])
			out.tls.utls = { enabled: true, fingerprint: params["fp"] };
		if (security === "reality" && params["pbk"])
			out.tls.reality = { enabled: true, public_key: params["pbk"] };
	}

	let transport_type = params["type"];
	if (transport_type && transport_type !== "tcp")
		out.transport = { type: transport_type };

	return out;
}

function parse_hy2(url) {
	// hy2://password@host:port?params  (also hysteria2://)
	let m = match(url, /^hy2:\/\/([^@]+)@([^:/?#]+):([0-9]+)(\?[^#]*)?/) ||
	        match(url, /^hysteria2:\/\/([^@]+)@([^:/?#]+):([0-9]+)(\?[^#]*)?/);
	if (!m) return null;
	let password = m[1];
	let host = m[2];
	let port = +m[3];
	let params = m[4] ? parse_query(substr(m[4], 1)) : {};

	let out = {
		type: "hysteria2",
		server: host,
		server_port: port,
		password: password,
		tls: { enabled: true, server_name: params["sni"] ?? host },
	};

	if (params["obfs"] === "salamander") {
		out.obfs = { type: "salamander", password: params["obfs-password"] ?? "" };
	}

	return out;
}

function parse_proxy_url(url) {
	if (match(url, /^vless:\/\//))    return parse_vless(url);
	if (match(url, /^hy2:\/\//) ||
	    match(url, /^hysteria2:\/\//)) return parse_hy2(url);
	warn("generate.uc: unsupported proxy URL scheme: " + url + "\n");
	return null;
}

function parse_json_outbound(json_str, name) {
	let parsed = json(json_str ?? "");
	if (!parsed || type(parsed) !== "object") {
		warn("generate.uc: invalid JSON outbound for " + name + "\n");
		return null;
	}
	parsed.tag = name;
	return parsed;
}

function build_outbounds_and_routes() {
	let outbounds = [];
	let route_rules = [];
	let route_rule_sets = [];

	uci.foreach("singbox-ui", "outbound", function(section) {
		if (section.enabled === "0") return;   // skip disabled outbounds

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
				let parsed = parse_proxy_url(section.proxy_url ?? "");
				if (parsed) {
					parsed.tag = name;
					outbound = parsed;
				}
			} else if (proxy_type === "json") {
				outbound = parse_json_outbound(section.proxy_json, name);
			}
		}

		if (!outbound) return;
		push(outbounds, outbound);

		// Build routing rule from Conditions tab fields.
		let rulesets = section.ruleset ?? [];
		if (type(rulesets) === "string") rulesets = [ rulesets ];
		let domains = section.domain ?? [];
		if (type(domains) === "string") domains = [ domains ];

		if (!length(rulesets) && !length(domains)) return;

		let rule = { outbound: name };
		let rs_tags = [];

		for (let i, rs in rulesets) {
			let rs_tag = "rs_" + name + "_" + i;
			let is_local = (substr(rs, 0, 1) === "/");
			let format = match(rs, /\.srs$/) ? "binary" : "source";
			let rs_obj;
			if (is_local) {
				rs_obj = { tag: rs_tag, type: "local", format: format, path: rs };
			} else {
				rs_obj = { tag: rs_tag, type: "remote", format: format, url: rs };
			}
			push(route_rule_sets, rs_obj);
			push(rs_tags, rs_tag);
		}

		if (length(rs_tags)) rule.rule_set = rs_tags;
		if (length(domains)) rule.domain_suffix = domains;

		push(route_rules, rule);
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
