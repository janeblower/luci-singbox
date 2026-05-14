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

// First entry of a UCI list option as a plain string, or null if absent.
// Accepts an `option` value (already a string) too.
function get_first(section, opt) {
	let v = uci.get("singbox-ui", section, opt);
	if (v == null) return null;
	if (type(v) === "array") return length(v) ? v[0] : null;
	return v;
}

function url_decode(s) {
	if (s == null) return s;
	// Replace + with space, then percent-decode.
	let out = replace(s, "+", " ");
	return replace(out, /%([0-9a-fA-F]{2})/g, function(m, h) {
		return chr(hex(h));
	});
}

function parse_query(query_string) {
	let params = {};
	for (let part in split(query_string, "&")) {
		let eq = index(part, "=");
		if (eq < 0) continue;
		let k = substr(part, 0, eq);
		let v = substr(part, eq + 1);
		params[k] = url_decode(v);
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

function read_subscription_urls(name) {
	let path = "/tmp/singbox-ui/sub_" + name + ".txt";
	let f = fs.open(path, "r");
	if (!f) {
		warn("generate.uc: subscription state missing: " + path + "\n");
		return [];
	}
	let body = f.read("all") ?? "";
	f.close();
	let urls = [];
	for (let line in split(body, "\n")) {
		let t = trim(line);
		if (length(t)) push(urls, t);
	}
	return urls;
}

function build_outbounds() {
	let outbounds = [];

	uci.foreach("singbox-ui", "outbound", function(section) {
		if (section.enabled === "0") return;

		let name = section[".name"];
		let proxy_type = section.proxy_type;
		let outbound = null;

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
		} else if (proxy_type === "subscription") {
			let urls = read_subscription_urls(name);
			if (!length(urls)) return;

			if (section.sub_multi === "1") {
				let children = [];
				let i = 0;
				for (let u in urls) {
					let parsed = parse_proxy_url(u);
					if (!parsed) { i++; continue; }
					let tag = name + "__" + i;
					parsed.tag = tag;
					push(outbounds, parsed);
					push(children, tag);
					i++;
				}
				if (length(children)) {
					let selector_type = section.sub_selector_type ?? "selector";
					push(outbounds, {
						tag: name,
						type: selector_type,
						outbounds: children,
					});
				}
				return;  // done with this section
			}

			// Single-URL fallback (sub_multi=0): pick the first parseable one.
			for (let u in urls) {
				let parsed = parse_proxy_url(u);
				if (parsed) {
					parsed.tag = name;
					outbound = parsed;
					break;
				}
			}
		}

		if (!outbound) return;
		push(outbounds, outbound);
	});

	return outbounds;
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
					format: rs.format ?? "binary",
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
	let v4 = get_first("fakeip", "inet4_range");
	let v6 = get_first("fakeip", "inet6_range");
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

let outbounds = build_outbounds();
if (length(outbounds)) config.outbounds = outbounds;

let route = build_route_config();
if (length(route.rules) || route.final) {
	config.route = {};
	if (length(route.rules))     config.route.rules     = route.rules;
	if (length(route.rule_sets)) config.route.rule_set  = route.rule_sets;
	if (route.final && route.final !== "direct")
		config.route.final = route.final;
}

let f = fs.open("/tmp/singbox-ui.json", "w");
if (!f) {
	warn("generate.uc: cannot open /tmp/singbox-ui.json for writing\n");
	exit(1);
}
f.write(sprintf("%.4J\n", config));
f.close();

print("OK\n");
