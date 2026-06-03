// lib/outbound.uc — sing-box `outbounds` builder + share-link / JSON / subscription parsers.

const TMPDIR = getenv("SINGBOX_TMPDIR") || "/tmp/singbox-ui";

let fs = require("fs");
let helpers = require("helpers");

function s_opt(s, k) { let v = s[k]; return (v == null) ? "" : v; }
function s_bool(s, k) { return s[k] === "1"; }
function s_num(v) { let n = +v; return n || 0; }
function csv_list(v) {
	if (v == null || v === "") return [];
	let out = [];
	for (let p in split(v, ",")) { let t = trim(p); if (length(t)) push(out, t); }
	return out;
}
function merge_extra(obj, json_str) {
	if (json_str == null || json_str === "") return;
	let extra;
	try { extra = json(json_str); } catch (e) { extra = null; }
	if (type(extra) !== "object") { warn("outbound.uc: invalid extra_json; ignored\n"); return; }
	for (let k in extra) obj[k] = extra[k];
}

// Client-side TLS. null when security=none. hysteria2 forces tls.
function build_tls_client(s) {
	let sec = s_opt(s, "security") || "none";
	if (s.protocol === "hysteria2") sec = "tls";
	if (sec === "none") return null;
	let tls = { enabled: true };
	if (length(s_opt(s, "tls_server_name"))) tls.server_name = s.tls_server_name;
	if (s_bool(s, "tls_insecure")) tls.insecure = true;
	let alpn = csv_list(s_opt(s, "tls_alpn"));
	if (length(alpn)) tls.alpn = alpn;
	if (length(s_opt(s, "utls_fingerprint")))
		tls.utls = { enabled: true, fingerprint: s.utls_fingerprint };
	if (sec === "reality") {
		let r = { enabled: true };
		if (length(s_opt(s, "reality_public_key"))) r.public_key = s.reality_public_key;
		if (length(s_opt(s, "reality_short_id")))   r.short_id   = s.reality_short_id;
		tls.reality = r;
	}
	return tls;
}

function build_transport(s) {
	let t = s_opt(s, "transport") || "none";
	if (t === "none") return null;
	let tr = { type: t };
	if (t === "ws") {
		if (length(s_opt(s, "transport_path"))) tr.path = s.transport_path;
		if (length(s_opt(s, "transport_host"))) tr.headers = { Host: s.transport_host };
	} else if (t === "httpupgrade") {
		if (length(s_opt(s, "transport_path"))) tr.path = s.transport_path;
		if (length(s_opt(s, "transport_host"))) tr.host = s.transport_host;
	} else if (t === "grpc") {
		if (length(s_opt(s, "transport_service_name"))) tr.service_name = s.transport_service_name;
	}
	return tr;
}

function build_constructor(s) {
	let proto = s_opt(s, "protocol");
	if (!length(proto)) { warn("outbound.uc: constructor without protocol; skipping\n"); return null; }
	let ob = { type: proto, tag: s[".name"], server: s_opt(s, "server"), server_port: s_num(s.server_port) };

	if (proto === "vless" || proto === "vmess") {
		if (length(s_opt(s, "server_uuid"))) ob.uuid = s.server_uuid;
	}
	if (proto === "trojan" || proto === "hysteria2" || proto === "shadowsocks") {
		if (length(s_opt(s, "server_password"))) ob.password = s.server_password;
	}
	if (proto === "vless" && length(s_opt(s, "vless_flow")) && s.vless_flow !== "none")
		ob.flow = s.vless_flow;
	if (proto === "vmess") {
		ob.alter_id = s_num(s.vmess_alter_id);
		if (length(s_opt(s, "vmess_security"))) ob.security = s.vmess_security;
	}
	if (proto === "shadowsocks")
		ob.method = s_opt(s, "shadowsocks_method") || "aes-128-gcm";
	if (proto === "hysteria2") {
		let ot = s_opt(s, "hysteria2_obfs_type") || "none";
		if (ot !== "none" && length(s_opt(s, "hysteria2_obfs_password")))
			ob.obfs = { type: ot, password: s.hysteria2_obfs_password };
		if (length(s_opt(s, "up_mbps")))   ob.up_mbps   = s_num(s.up_mbps);
		if (length(s_opt(s, "down_mbps"))) ob.down_mbps = s_num(s.down_mbps);
	}
	if (proto !== "shadowsocks") {
		let tls = build_tls_client(s);
		if (tls) ob.tls = tls;
	}
	if (proto === "vless" || proto === "vmess" || proto === "trojan") {
		let tr = build_transport(s);
		if (tr) ob.transport = tr;
	}
	merge_extra(ob, s_opt(s, "extra_json"));
	return ob;
}

function url_decode(s) {
	if (s == null) return s;
	// Replace + with space, then percent-decode.
	let out = replace(s, "+", " ");
	return replace(out, /%([0-9a-fA-F]{2})/g, function(m, h) { return chr(hex(h)); });
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
	let uuid = m[1], host = m[2], port = +m[3];
	let params = m[4] ? parse_query(substr(m[4], 1)) : {};
	let out = { type: "vless", server: host, server_port: port, uuid: uuid };
	let security = params["security"];
	if (security === "tls" || security === "reality") {
		let sni = params["sni"] ?? host;
		out.tls = { enabled: true, server_name: sni };
		if (params["fp"]) out.tls.utls = { enabled: true, fingerprint: params["fp"] };
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
	let password = m[1], host = m[2], port = +m[3];
	let params = m[4] ? parse_query(substr(m[4], 1)) : {};
	let out = {
		type: "hysteria2", server: host, server_port: port, password: password,
		tls: { enabled: true, server_name: params["sni"] ?? host },
	};
	if (params["obfs"] === "salamander")
		out.obfs = { type: "salamander", password: params["obfs-password"] ?? "" };
	return out;
}

function parse_proxy_url(url) {
	if (match(url, /^vless:\/\//))     return parse_vless(url);
	if (match(url, /^hy2:\/\//) ||
	    match(url, /^hysteria2:\/\//)) return parse_hy2(url);
	warn("outbound.uc: unsupported proxy URL scheme: " + url + "\n");
	return null;
}

function parse_json_outbound(json_str, name) {
	let parsed = json(json_str ?? "");
	if (!parsed || type(parsed) !== "object") {
		warn("outbound.uc: invalid JSON outbound for " + name + "\n");
		return null;
	}
	parsed.tag = name;
	return parsed;
}

function read_subscription_urls(name) {
	let path = `${TMPDIR}/sub_${name}.txt`;
	let f = fs.open(path, "r");
	if (!f) {
		warn("outbound.uc: subscription state missing: " + path + "\n");
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

function build_outbounds(cur) {
	let outbounds = [];

	cur.foreach("singbox-ui", "outbound", function(section) {
		if (section.enabled === "0") return;

		let name = section[".name"];
		let proxy_type = section.proxy_type;
		let outbound = null;

		if (proxy_type === "interface") {
			// UCI logical name (e.g. "wan") → Linux netdev (e.g. "eth0").
			// sing-box bind_interface expects a real device name. Falls
			// back to the input verbatim if resolution fails (so a user
			// who already typed a real device name keeps working).
			let dev = helpers.resolve_iface_device(section.interface);
			outbound = { tag: name, type: "direct", bind_interface: dev };
		} else if (proxy_type === "url") {
			let parsed = parse_proxy_url(section.proxy_url ?? "");
			if (parsed) { parsed.tag = name; outbound = parsed; }
		} else if (proxy_type === "json") {
			outbound = parse_json_outbound(section.proxy_json, name);
		} else if (proxy_type === "constructor") {
			outbound = build_constructor(section);
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
					let group = { tag: name, type: selector_type, outbounds: children };
					if (selector_type === "urltest" && section.sub_urltest_url)
						group.url = section.sub_urltest_url;
					push(outbounds, group);
				}
				return;  // done with this section
			}

			// Single-URL fallback (sub_multi=0): pick the first parseable one.
			for (let u in urls) {
				let parsed = parse_proxy_url(u);
				if (parsed) { parsed.tag = name; outbound = parsed; break; }
			}
		}

		if (!outbound) return;
		push(outbounds, outbound);
	});

	return outbounds;
}

return { build_outbounds };
