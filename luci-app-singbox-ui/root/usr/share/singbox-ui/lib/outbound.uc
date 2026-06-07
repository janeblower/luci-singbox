// lib/outbound.uc — sing-box `outbounds` builder + share-link / JSON / subscription parsers.

const TMPDIR = getenv("SINGBOX_TMPDIR") || "/tmp/singbox-ui";

let fs = require("fs");
let helpers = require("helpers");

// C3.1: eagerly load descriptor modules so their register() calls fire at
// module load. Wrapped in try/catch so an absent descriptor never breaks
// the legacy dispatcher — it just falls through to the switch-by-type below.
try { require("protocols.ssh"); } catch (_) {}
try { require("protocols.trojan"); } catch (_) {}
try { require("protocols.shadowsocks"); } catch (_) {}

const s_opt    = helpers.s_opt;
const s_bool   = helpers.s_bool;
const s_num    = helpers.s_num;
const csv_list = helpers.csv_list;
const as_array = helpers.as_array;
const fnv1a32  = helpers.fnv1a32;
// Client-side TLS. null when security=none. hysteria2 forces tls.
function build_tls_client(s, proto) {
	let sec = s_opt(s, "security") || "none";
	if (proto === "hysteria2") sec = "tls";
	if (sec === "none") return null;
	let tls = { enabled: true };
	if (length(s_opt(s, "tls_server_name"))) tls.server_name = s.tls_server_name;
	if (s_bool(s, "tls_insecure")) tls.insecure = true;
	let alpn = as_array(s.tls_alpn);
	if (length(alpn)) tls.alpn = alpn;
	if (length(s_opt(s, "utls_fingerprint")))
		tls.utls = { enabled: true, fingerprint: s.utls_fingerprint };
	if (sec === "reality") {
		let r = { enabled: true };
		if (length(s_opt(s, "reality_public_key"))) r.public_key = s.reality_public_key;
		if (length(s_opt(s, "reality_short_id")))   r.short_id   = s.reality_short_id;
		tls.reality = r;
	}
	// ECH (client-side): config/config_path are client-only.
	// pq_signature_schemes_enabled is deprecated in 1.12 and removed in 1.13 — never emitted.
	if (s_bool(s, "tls_ech")) {
		let ech = { enabled: true };
		let cfg = as_array(s.tls_ech_config);
		if (length(cfg)) ech.config = cfg;
		if (length(s_opt(s, "tls_ech_config_path"))) ech.config_path = s.tls_ech_config_path;
		tls.ech = ech;
	}
	// TLS fragmentation (client-only, Since sing-box 1.12). Flat fields in tls.
	if (s_bool(s, "tls_fragment")) tls.fragment = true;
	if (length(s_opt(s, "tls_fragment_fallback_delay")))
		tls.fragment_fallback_delay = s.tls_fragment_fallback_delay;
	if (s_bool(s, "tls_record_fragment")) tls.record_fragment = true;
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
	} else if (t === "xhttp") {
		if (length(s_opt(s, "transport_path"))) tr.path = s.transport_path;
		if (length(s_opt(s, "transport_xhttp_mode"))) tr.mode = s.transport_xhttp_mode;
	} else if (t === "http") {
		let hosts = as_array(s.transport_hosts);
		if (length(hosts)) tr.host = hosts;
		if (length(s_opt(s, "transport_path"))) tr.path = s.transport_path;
	}
	return tr;
}

function build_multiplex(s) {
	if (!s_bool(s, "multiplex_enabled")) return null;
	let m = { enabled: true };
	if (length(s_opt(s, "multiplex_protocol"))) m.protocol = s.multiplex_protocol;
	if (length(s_opt(s, "multiplex_max_connections")))
		m.max_connections = s_num(s.multiplex_max_connections);
	if (length(s_opt(s, "multiplex_min_streams")))
		m.min_streams = s_num(s.multiplex_min_streams);
	if (length(s_opt(s, "multiplex_max_streams")))
		m.max_streams = s_num(s.multiplex_max_streams);
	if (s_bool(s, "multiplex_padding")) m.padding = true;
	return m;
}

function build_constructor_for(s, proto) {
	// C3.1: consult protocol registry first. If a descriptor is registered
	// for ("outbound", proto), use its emit() and skip the legacy switch
	// entirely. Wrapped in try/catch so registry loading errors never
	// break the legacy code path.
	try {
		let reg = require("protocols.registry");
		let d = reg.get("outbound", proto);
		if (d != null) return d.emit(s);
	} catch (_) { /* registry not available — fall through to legacy switch */ }

	let ob = { type: proto, tag: s[".name"], server: s_opt(s, "server"), server_port: s_num(s.server_port) };

	if (proto === "vless" || proto === "vmess") {
		if (length(s_opt(s, "server_uuid"))) ob.uuid = s.server_uuid;
	}
	if (proto === "hysteria2") {
		if (length(s_opt(s, "server_password"))) ob.password = s.server_password;
	}
	if (proto === "tuic") {
		if (length(s_opt(s, "server_uuid")))     ob.uuid     = s.server_uuid;
		if (length(s_opt(s, "server_password"))) ob.password = s.server_password;
		if (length(s_opt(s, "tuic_congestion")))
			ob.congestion_control = s.tuic_congestion;
		let over_stream = s_bool(s, "tuic_udp_over_stream");
		if (over_stream) ob.udp_over_stream = true;
		// udp_relay_mode is mutually exclusive with udp_over_stream — drop it when over_stream is on.
		if (!over_stream && length(s_opt(s, "tuic_udp_relay_mode")))
			ob.udp_relay_mode = s.tuic_udp_relay_mode;
		if (s_bool(s, "tuic_zero_rtt")) ob.zero_rtt_handshake = true;
		if (length(s_opt(s, "tuic_heartbeat"))) ob.heartbeat = s.tuic_heartbeat;
		if (length(s_opt(s, "network")) && (s.network === "tcp" || s.network === "udp"))
			ob.network = s.network;
	}
	if (proto === "anytls") {
		if (length(s_opt(s, "server_password"))) ob.password = s.server_password;
		if (length(s_opt(s, "anytls_idle_check_interval")))
			ob.idle_session_check_interval = s.anytls_idle_check_interval;
		if (length(s_opt(s, "anytls_idle_timeout")))
			ob.idle_session_timeout = s.anytls_idle_timeout;
		let m = s_num(s.anytls_min_idle_session);
		if (m > 0) ob.min_idle_session = m;
	}
	if (proto === "vless" && length(s_opt(s, "vless_flow")) && s.vless_flow !== "none")
		ob.flow = s.vless_flow;
	if (proto === "vmess") {
		if (length(s_opt(s, "vmess_alter_id"))) ob.alter_id = s_num(s.vmess_alter_id);
		if (length(s_opt(s, "vmess_security"))) ob.security = s.vmess_security;
	}
	if (proto === "hysteria2") {
		let ot = s_opt(s, "hysteria2_obfs_type") || "none";
		// 1.12: only "salamander" is defined; "gecko" lands in 1.14.
		if (ot !== "none" && length(s_opt(s, "hysteria2_obfs_password")))
			ob.obfs = { type: ot, password: s.hysteria2_obfs_password };
		if (length(s_opt(s, "up_mbps")))   ob.up_mbps   = s_num(s.up_mbps);
		if (length(s_opt(s, "down_mbps"))) ob.down_mbps = s_num(s.down_mbps);
		if (length(s_opt(s, "hysteria2_masquerade")))
			ob.masquerade = s.hysteria2_masquerade;
		if (s_bool(s, "brutal_debug")) ob.brutal_debug = true;
		if (length(s_opt(s, "network")) && (s.network === "tcp" || s.network === "udp"))
			ob.network = s.network;
	}
	// shadowsocks: no TLS in the protocol itself.
	// trojan: descriptor-owned (D1.1) — fallback must not double-emit tls.
	if (proto !== "shadowsocks" && proto !== "trojan") {
		let tls = build_tls_client(s, proto);
		if (tls) ob.tls = tls;
	}
	if (proto === "vless" || proto === "vmess") {
		let tr = build_transport(s);
		if (tr) ob.transport = tr;
		let mux = build_multiplex(s);
		if (mux) ob.multiplex = mux;
	}
	return ob;
}

// drop_ctrl(s) — drop bytes < 0x20 from a string. Used to scrub already-
// decoded bytes (from base64, JSON, etc.) where url_decode's percent-decoder
// doesn't apply. Hostile share-link sources should not be able to inject
// NUL/CR/LF/TAB into UCI fields through any decoding path.
function drop_ctrl(s) {
	if (s == null) return s;
	let out = "";
	for (let i = 0; i < length(s); i++) {
		let b = ord(s, i);
		if (b >= 0x20) out += chr(b);
	}
	return out;
}

function url_decode(s) {
	if (s == null) return s;
	// Replace + with space, then percent-decode. Drop control characters
	// (< 0x20) silently — a hostile subscription server should not be able
	// to inject NUL/CR/LF/TAB into UCI-stored values that later land in
	// config.json or get referenced by route rules.
	let out = replace(s, "+", " ");
	return drop_ctrl(replace(out, /%([0-9a-fA-F]{2})/g, function(m, h) {
		return chr(hex(h));
	}));
}

// safe_tag(raw, seed) — return raw if it matches the conservative tag
// whitelist; otherwise generate a stable 'imported-<fnv1a hex>' tag from
// the provided seed (typically the share-link URL itself). Tags appear in
// the rendered config.json and are referenced by route rules; an attacker
// who controls the source must not be able to inject arbitrary bytes here.
// The user can rename the imported tag in the UI after import.
function safe_tag(raw, seed) {
	if (raw != null && length(raw) && match(raw, /^[A-Za-z0-9_.\-]+$/))
		return raw;
	return sprintf("imported-%s", fnv1a32(seed || "anon"));
}

// safe_host(raw) — return raw if it looks like a domain, IPv4, or IPv6;
// otherwise null. Used to fail the parser early on hosts containing bytes
// that have no business in a host string (whitespace, control chars,
// non-ASCII). sing-box itself does stricter validation downstream; this
// is a defence-in-depth check so a malformed outbound section can't land
// in UCI in the first place.
function safe_host(raw) {
	if (raw == null || !length(raw)) return null;
	if (match(raw, /^[A-Za-z0-9.\-]+$/))   return raw;  // domain | IPv4
	if (match(raw, /^\[[0-9a-fA-F:]+\]$/)) return raw;  // [IPv6]
	if (match(raw, /^[0-9a-fA-F:]+$/) && index(raw, ":") >= 0)
		return raw;                                     // bare IPv6
	return null;
}

// safe_port(raw) — return integer 1..65535 or null.
function safe_port(raw) {
	let n = (type(raw) === "int") ? raw : +raw;
	if (type(n) !== "int" || n < 1 || n > 65535) return null;
	return n;
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
	let uuid = url_decode(m[1]);
	let host = safe_host(m[2]);
	let port = safe_port(m[3]);
	if (!length(uuid) || !host || !port) return null;
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
	let password = url_decode(m[1]);
	let host = safe_host(m[2]);
	let port = safe_port(m[3]);
	if (!length(password) || !host || !port) return null;
	let params = m[4] ? parse_query(substr(m[4], 1)) : {};
	let out = {
		type: "hysteria2", server: host, server_port: port, password: password,
		tls: { enabled: true, server_name: params["sni"] ?? host },
	};
	if (params["obfs"] === "salamander")
		out.obfs = { type: "salamander", password: params["obfs-password"] ?? "" };
	return out;
}

// b64_decode(s) — tolerant base64 decoder for share-link payloads.
// Accepts both standard and url-safe alphabets and missing padding.
// Returns the decoded string, or null on invalid input.
function b64_decode(s) {
	if (s == null) return null;
	// Strip whitespace, normalise url-safe alphabet.
	let t = replace(s, /\s+/g, "");
	t = replace(t, "-", "+");
	t = replace(t, "_", "/");
	let pad = length(t) % 4;
	if (pad === 2) t += "==";
	else if (pad === 3) t += "=";
	else if (pad === 1) return null;  // invalid base64 length
	let dec = null;
	try { dec = b64dec(t); } catch (e) { return null; }
	return dec;
}

// parse_vmess(url) — v2rayN base64-JSON format.
//   vmess://<base64(JSON)>
// JSON fields (case-sensitive): v, ps, add, port, id, aid|alterId, scy,
// net, type, host, path, tls, sni, alpn, fp.
// Returns a sing-box vmess outbound object, or null on parse failure.
function parse_vmess(url) {
	let m = match(url, /^vmess:\/\/(.+)$/);
	if (!m) return null;
	let payload = m[1];
	// Strip fragment if present — some clients include #name after the b64.
	let hash = index(payload, "#");
	if (hash >= 0) payload = substr(payload, 0, hash);
	let decoded = b64_decode(payload);
	if (decoded == null || !length(decoded)) return null;
	let j = null;
	try { j = json(decoded); } catch (e) { return null; }
	if (type(j) !== "object") return null;

	let add = safe_host(j.add);
	let id = j.id;
	let port = safe_port(j.port);
	if (!add || !length(id) || !port) return null;

	let name = j.ps;
	let out = {
		type: "vmess",
		tag: safe_tag(length(name) ? name : add, url),
		server: add,
		server_port: port,
		uuid: id,
	};
	// alter_id: accept `aid` or `alterId`, number or string.
	let aid = j.aid ?? j.alterId;
	if (aid != null) {
		if (type(aid) === "string") aid = +aid;
		// Only emit when set and > 0 (default 0 is implicit).
		if (type(aid) === "int" && aid > 0) out.alter_id = aid;
	}
	let scy = j.scy;
	if (length(scy) && scy !== "auto") out.security = scy;

	let tls_mode = j.tls;
	if (tls_mode === "tls" || tls_mode === "reality") {
		let tls = { enabled: true };
		let sni = j.sni;
		tls.server_name = length(sni) ? sni : add;
		let alpn = j.alpn;
		if (length(alpn)) {
			let list = [];
			for (let a in split(alpn, ",")) {
				let v = trim(a);
				if (length(v)) push(list, v);
			}
			if (length(list)) tls.alpn = list;
		}
		if (length(j.fp)) tls.utls = { enabled: true, fingerprint: j.fp };
		out.tls = tls;
	}

	let net = j.net;
	if (length(net) && net !== "tcp") {
		let tr = { type: net };
		if (net === "ws") {
			if (length(j.path)) tr.path = j.path;
			if (length(j.host)) tr.headers = { Host: j.host };
		} else if (net === "grpc") {
			if (length(j.path)) tr.service_name = j.path;
		} else if (net === "h2" || net === "http") {
			tr.type = "http";
			if (length(j.path)) tr.path = j.path;
			if (length(j.host)) {
				let hosts = [];
				for (let h in split(j.host, ",")) {
					let v = trim(h);
					if (length(v)) push(hosts, v);
				}
				if (length(hosts)) tr.host = hosts;
			}
		} else if (net === "xhttp") {
			if (length(j.path)) tr.path = j.path;
			if (length(j.type) && j.type !== "none") tr.mode = j.type;
		}
		out.transport = tr;
	}
	return out;
}

// parse_ss(url) — Shadowsocks share-link.
//   Plain:  ss://<method>:<password>@<host>:<port>[?plugin=...][#name]
//   Legacy: ss://<base64(method:password)>@<host>:<port>[#name]
//           (some clients base64 the entire method:password@host:port).
// Returns a sing-box shadowsocks outbound object, or null on parse failure.
function parse_ss(url) {
	let m = match(url, /^ss:\/\/([^#]*)(#.*)?$/);
	if (!m) return null;
	let body = m[1];
	let frag = m[2] ? url_decode(substr(m[2], 1)) : null;

	let method = null, password = null, host = null, port = null;

	let at = index(body, "@");
	if (at >= 0) {
		// Could be plain (method:password@host:port[?...]) or legacy with
		// base64(method:password)@host:port[?...].
		let userinfo = substr(body, 0, at);
		let tail = substr(body, at + 1);

		// Tail: host:port[?query]
		let q = index(tail, "?");
		let hp = q >= 0 ? substr(tail, 0, q) : tail;
		let hpm = match(hp, /^([^:]+):([0-9]+)$/);
		if (!hpm) return null;
		host = hpm[1]; port = +hpm[2];

		// userinfo: either "method:password" plain, or base64.
		let colon = index(userinfo, ":");
		if (colon >= 0) {
			method   = url_decode(substr(userinfo, 0, colon));
			password = url_decode(substr(userinfo, colon + 1));
		} else {
			let dec = b64_decode(userinfo);
			if (dec == null) return null;
			let dcolon = index(dec, ":");
			if (dcolon < 0) return null;
			method   = drop_ctrl(substr(dec, 0, dcolon));
			password = drop_ctrl(substr(dec, dcolon + 1));
		}
	} else {
		// No '@' in the body. Entire body must be base64 of full
		// "method:password@host:port".
		let dec = b64_decode(body);
		if (dec == null) return null;
		let dat = index(dec, "@");
		if (dat < 0) return null;
		let userinfo = substr(dec, 0, dat);
		let tail = substr(dec, dat + 1);
		let q = index(tail, "?");
		let hp = q >= 0 ? substr(tail, 0, q) : tail;
		let hpm = match(hp, /^([^:]+):([0-9]+)$/);
		if (!hpm) return null;
		host = hpm[1]; port = +hpm[2];
		let colon = index(userinfo, ":");
		if (colon < 0) return null;
		method   = drop_ctrl(substr(userinfo, 0, colon));
		password = drop_ctrl(substr(userinfo, colon + 1));
	}

	host = safe_host(host);
	port = safe_port(port);
	if (!length(method) || !length(password) || !host || !port)
		return null;

	let out = {
		type: "shadowsocks",
		tag: safe_tag(length(frag) ? frag : host, url),
		server: host,
		server_port: port,
		method: method,
		password: password,
	};
	return out;
}

// parse_trojan(url) — trojan-GFW share-link.
//   trojan://<password>@<host>:<port>[?sni=...&type=ws&path=...&allowInsecure=1][#name]
// Returns a sing-box trojan outbound object, or null on parse failure.
function parse_trojan(url) {
	let m = match(url, /^trojan:\/\/([^@]+)@([^:/?#]+):([0-9]+)(\?[^#]*)?(#.*)?$/);
	if (!m) return null;
	let password = url_decode(m[1]);
	let host = safe_host(m[2]);
	let port = safe_port(m[3]);
	if (!length(password) || !host || !port) return null;
	let params = m[4] ? parse_query(substr(m[4], 1)) : {};
	let frag = m[5] ? url_decode(substr(m[5], 1)) : null;

	let sni = params["sni"] ?? params["peer"] ?? host;
	let out = {
		type: "trojan",
		tag: safe_tag(length(frag) ? frag : host, url),
		server: host,
		server_port: port,
		password: password,
		tls: { enabled: true, server_name: sni },
	};
	if (params["allowInsecure"] === "1" || params["allowinsecure"] === "1")
		out.tls.insecure = true;
	if (length(params["alpn"])) {
		let list = [];
		for (let a in split(params["alpn"], ",")) {
			let v = trim(a);
			if (length(v)) push(list, v);
		}
		if (length(list)) out.tls.alpn = list;
	}
	if (length(params["fp"]))
		out.tls.utls = { enabled: true, fingerprint: params["fp"] };

	let tt = params["type"];
	if (length(tt) && tt !== "tcp") {
		let tr = { type: tt };
		if (tt === "ws") {
			if (length(params["path"])) tr.path = params["path"];
			if (length(params["host"])) tr.headers = { Host: params["host"] };
		} else if (tt === "grpc") {
			if (length(params["serviceName"]))   tr.service_name = params["serviceName"];
			else if (length(params["path"]))     tr.service_name = params["path"];
		}
		out.transport = tr;
	}
	return out;
}

function parse_proxy_url(url) {
	if (match(url, /^vless:\/\//))     return parse_vless(url);
	if (match(url, /^vmess:\/\//))     return parse_vmess(url);
	if (match(url, /^ss:\/\//))        return parse_ss(url);
	if (match(url, /^trojan:\/\//))    return parse_trojan(url);
	if (match(url, /^hy2:\/\//) ||
	    match(url, /^hysteria2:\/\//)) return parse_hy2(url);
	warn("outbound.uc: unsupported proxy URL scheme: " + url + "\n");
	return null;
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
		let kind = s_opt(section, "type");
		if (kind === "") return;          // unmigrated/empty section — skip
		let outbound = null;

		if (kind === "interface") {
			// UCI logical name (e.g. "wan") → Linux netdev (e.g. "eth0").
			// sing-box bind_interface expects a real device name. Falls
			// back to the input verbatim if resolution fails (so a user
			// who already typed a real device name keeps working).
			let dev = helpers.resolve_iface_device(section.interface);
			outbound = { tag: name, type: "direct", bind_interface: dev };
		} else if (kind === "url") {
			let parsed = parse_proxy_url(section.proxy_url ?? "");
			if (parsed) { parsed.tag = name; outbound = parsed; }
		} else if (helpers.is_outbound_proxy_kind(kind)) {
			outbound = build_constructor_for(section, kind);
		} else if (kind === "subscription") {
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
		} else {
			warn(sprintf("outbound.uc: unknown type '%s' for '%s'; skipping\n", kind, name));
			return;
		}

		if (!outbound) return;
		push(outbounds, outbound);
	});

	return outbounds;
}

return { build_outbounds, build_constructor_for, parse_proxy_url,
         build_tls_client, build_transport, build_multiplex };
