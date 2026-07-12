// lib/subformat.uc — subscription BODY parsing: format detection + the parsers
// for every format we accept. subscription.uc owns the network/cache side; this
// file owns "bytes in -> nodes out" and nothing else.
//
// The body is UNTRUSTED input (Phase-3 trust boundary): a malformed proxy entry
// must cost exactly one `skipped++`, never an exception that aborts the whole
// refresh and leaves the router without outbounds.
//
// Node record (the unit every parser produces, and the unit lib/outbound.uc
// consumes):  { outbound: <sing-box outbound object, no tag>, display_name, link }
//   - uri-list bodies keep their share-link in `link` (dashboard copy-link).
//   - Clash/JSON bodies have no share-link -> link is null.
//
// On-disk form (sub_<name>.txt) stays LINE based:
//   * a line starting with `{` is a JSON node record {"o":…,"n":…,"l":…}
//   * anything else is a share-link URI (unchanged, human-inspectable)
// parse_node() below is the single reader for both, used by lib/outbound.uc.
//
// NB: lib/clash.uc is the clash_api CLIENT (controls a running sing-box over
// HTTP). It has nothing to do with Clash YAML. This is the YAML parser.

let helpers   = require("helpers");
let sharelink = require("sharelink");

// sing-box outbound types we accept from a JSON subscription. A subscription
// has no business shipping `direct`/`block`/`selector`/`urltest` — those are
// local policy, and honouring them from a hostile feed would let the provider
// redirect traffic. Anything not on this list is skipped.
const JSON_PROXY_TYPES = {
	shadowsocks: true, shadowtls: true, vmess: true, vless: true, trojan: true,
	hysteria: true, hysteria2: true, tuic: true, anytls: true,
	socks: true, http: true, ssh: true, wireguard: true,
};

// ---------------------------------------------------------------- YAML subset

function unquote(s) {
	let n = length(s);
	if (n >= 2) {
		let a = substr(s, 0, 1), b = substr(s, n - 1, 1);
		if ((a === '"' && b === '"') || (a === "'" && b === "'"))
			return substr(s, 1, n - 2);
	}
	return s;
}

// split_top(s) — split on top-level commas only (skip commas inside {}/[]/quotes).
function split_top(s) {
	let parts = [], depth = 0, cur = "", q = "";
	for (let i = 0; i < length(s); i++) {
		let ch = substr(s, i, 1);
		if (q !== "") { cur += ch; if (ch === q) q = ""; continue; }
		if (ch === '"' || ch === "'") { q = ch; cur += ch; continue; }
		if (ch === "{" || ch === "[") depth++;
		else if (ch === "}" || ch === "]") depth--;
		else if (ch === "," && depth <= 0) { push(parts, cur); cur = ""; continue; }
		cur += ch;
	}
	if (trim(cur) !== "") push(parts, cur);
	return parts;
}

// scalar() is mutually recursive with the inline map/list readers, and ucode
// resolves top-level `function` declarations in source order — so the two
// readers are `let` bindings assigned AFTER scalar() is declared.
let inline_map, inline_list;

function scalar(s) {
	s = trim(s);
	if (s === "") return "";
	let c = substr(s, 0, 1);
	if (c === '"' || c === "'") return unquote(s);
	if (c === "{") return inline_map(s);
	if (c === "[") return inline_list(s);
	// trailing `# comment` on an unquoted scalar
	let h = index(s, " #");
	if (h >= 0) s = trim(substr(s, 0, h));
	if (s === "true")  return true;
	if (s === "false") return false;
	if (match(s, /^-?[0-9]+$/)) return +s;
	return s;
}

inline_map = function(s) {
	let m = {};
	let body = trim(substr(s, 1, length(s) - 2));
	for (let part in split_top(body)) {
		let p = trim(part);
		let c = index(p, ":");
		if (c < 0) continue;
		m[unquote(trim(substr(p, 0, c)))] = scalar(substr(p, c + 1));
	}
	return m;
};

inline_list = function(s) {
	let a = [];
	let body = trim(substr(s, 1, length(s) - 2));
	for (let part in split_top(body)) {
		let v = scalar(part);
		if (v !== "") push(a, v);
	}
	return a;
};

// scan_lines(body) — drop blanks/comments, record each line's indent column.
function scan_lines(body) {
	let out = [];
	for (let raw in split(body, "\n")) {
		let line = replace(raw, /\r+$/, "");
		line = replace(line, "\t", "  ");     // tabs are illegal YAML indent anyway
		let t = trim(line);
		if (t === "" || substr(t, 0, 1) === "#") continue;
		let ind = 0;
		while (substr(line, ind, 1) === " ") ind++;
		push(out, { indent: ind, text: t });
	}
	return out;
}

let parse_any;   // forward decl: parse_map/parse_list recurse through it

function parse_map(L, pos, indent) {
	let m = {};
	while (pos < length(L)) {
		let ln = L[pos];
		if (ln.indent < indent) break;
		if (substr(ln.text, 0, 1) === "-" && ln.indent === indent) break;
		if (ln.indent > indent) { pos++; continue; }   // stray deeper line: ignore
		let mm = match(ln.text, /^([^:]+):[ \t]*(.*)$/);
		if (!mm) { pos++; continue; }
		let k = unquote(trim(mm[1]));
		let v = trim(mm[2]);
		if (v === "" && pos + 1 < length(L) && L[pos + 1].indent > indent) {
			let r = parse_any(L, pos + 1, L[pos + 1].indent);
			m[k] = r.val;
			pos = r.pos;
		} else {
			m[k] = scalar(v);
			pos++;
		}
	}
	return { val: m, pos: pos };
}

function parse_list(L, pos, indent) {
	let arr = [];
	while (pos < length(L)) {
		let ln = L[pos];
		if (ln.indent < indent) break;
		if (ln.indent > indent || substr(ln.text, 0, 1) !== "-") { pos++; continue; }
		let rest = substr(ln.text, 1);
		let sp = 0;
		while (substr(rest, sp, 1) === " ") sp++;
		let content = trim(rest);
		let col = ln.indent + 1 + sp;
		if (content === "") {
			if (pos + 1 < length(L) && L[pos + 1].indent > indent) {
				let r = parse_any(L, pos + 1, L[pos + 1].indent);
				push(arr, r.val);
				pos = r.pos;
			} else pos++;
			continue;
		}
		if (substr(content, 0, 1) === "{" || substr(content, 0, 1) === "[") {
			push(arr, scalar(content));
			pos++;
			continue;
		}
		if (match(content, /^[^:]+:/)) {
			// block map whose first key sits on the dash line: re-feed it as a
			// synthetic line at the content column, followed by the deeper lines.
			let vl = [ { indent: col, text: content } ];
			let p = pos + 1;
			while (p < length(L) && L[p].indent > ln.indent) { push(vl, L[p]); p++; }
			let r = parse_map(vl, 0, col);
			push(arr, r.val);
			pos = p;
			continue;
		}
		push(arr, scalar(content));
		pos++;
	}
	return { val: arr, pos: pos };
}

parse_any = function(L, pos, indent) {
	if (pos < length(L) && substr(L[pos].text, 0, 1) === "-")
		return parse_list(L, pos, indent);
	return parse_map(L, pos, indent);
};

// yaml_proxies(body) — pull ONLY the top-level `proxies:` list out of a Clash /
// Mihomo config. Everything else (rules, proxy-groups, dns) is irrelevant to us
// and is not parsed at all.
function yaml_proxies(body) {
	let L = scan_lines(body);
	for (let i = 0; i < length(L); i++) {
		if (L[i].indent !== 0) continue;
		if (!match(L[i].text, /^["']?proxies["']?:/)) continue;
		let inline = trim(substr(L[i].text, index(L[i].text, ":") + 1));
		if (substr(inline, 0, 1) === "[") {
			let v = scalar(inline);
			return (type(v) === "array") ? v : [];
		}
		if (i + 1 >= length(L)) return [];
		let r = parse_any(L, i + 1, L[i + 1].indent);
		return (type(r.val) === "array") ? r.val : [];
	}
	return [];
}

// ------------------------------------------------------- Clash -> sing-box

function s_of(v) { return (v == null) ? "" : "" + v; }

function port_of(p) {
	let n = +p.port;
	return (n > 0 && n < 65536) ? n : 0;
}

function alpn_of(v) {
	if (v == null || v === "") return null;
	if (type(v) === "array") return v;
	return [ "" + v ];
}

function is_yes(v) { return v === true || v === "true" || v === 1 || v === "1"; }

// clash_tls(p, force) — the TLS block shared by every Clash type. `force` is for
// protocols where TLS is not optional (trojan, hysteria2).
function clash_tls(p, force) {
	let reality = p["reality-opts"];
	let want = force || is_yes(p.tls) || type(reality) === "object";
	if (!want) return null;
	let t = { enabled: true };
	let sni = p.servername ?? p.sni ?? p["peer"];
	if (sni != null && sni !== "") t.server_name = "" + sni;
	if (is_yes(p["skip-cert-verify"])) t.insecure = true;
	let alpn = alpn_of(p.alpn);
	if (alpn) t.alpn = alpn;
	let fp = p["client-fingerprint"];
	if (fp != null && fp !== "" && fp !== "none")
		t.utls = { enabled: true, fingerprint: "" + fp };
	if (type(reality) === "object") {
		let r = { enabled: true };
		if (reality["public-key"] != null) r.public_key = "" + reality["public-key"];
		if (reality["short-id"]  != null)  r.short_id  = "" + reality["short-id"];
		t.reality = r;
		// reality needs uTLS; chrome is what every client defaults to.
		if (!t.utls) t.utls = { enabled: true, fingerprint: "chrome" };
	}
	return t;
}

function clash_transport(p) {
	let net = s_of(p.network);
	if (net === "ws") {
		let t = { type: "ws" };
		let o = p["ws-opts"];
		let path = (type(o) === "object") ? o.path : p["ws-path"];
		t.path = (path != null && path !== "") ? "" + path : "/";
		let hdrs = (type(o) === "object") ? o.headers : p["ws-headers"];
		if (type(hdrs) === "object") {
			let h = {};
			for (let k in hdrs) h[k] = "" + hdrs[k];
			if (length(h)) t.headers = h;
		}
		if (type(o) === "object" && +o["max-early-data"] > 0) {
			t.max_early_data = +o["max-early-data"];
			if (o["early-data-header-name"] != null)
				t.early_data_header_name = "" + o["early-data-header-name"];
		}
		return t;
	}
	if (net === "grpc") {
		let o = p["grpc-opts"];
		let t = { type: "grpc" };
		if (type(o) === "object" && o["grpc-service-name"] != null)
			t.service_name = "" + o["grpc-service-name"];
		return t;
	}
	if (net === "h2" || net === "http") {
		let o = p["h2-opts"] ?? p["http-opts"];
		let t = { type: "http" };
		if (type(o) === "object") {
			if (o.path != null && o.path !== "")
				t.path = (type(o.path) === "array") ? "" + o.path[0] : "" + o.path;
			let host = o.host;
			if (host != null && host !== "")
				t.host = (type(host) === "array") ? host : [ "" + host ];
		}
		return t;
	}
	return null;   // tcp / unset
}

// clash_ss_plugin(p, o) — obfs / v2ray-plugin. sing-box takes the plugin name
// plus a `k=v;k=v` option string.
function clash_ss_plugin(p, o) {
	let plug = s_of(p.plugin);
	let po = p["plugin-opts"];
	if (plug === "" && p.obfs != null) { plug = "obfs"; po = { mode: p.obfs, host: p["obfs-host"] }; }
	if (plug === "") return;
	let opts = [];
	if (type(po) === "object") {
		if (plug === "obfs") {
			if (po.mode != null) push(opts, "obfs=" + po.mode);
			if (po.host != null) push(opts, "obfs-host=" + po.host);
			o.plugin = "obfs-local";
		} else if (plug === "v2ray-plugin") {
			push(opts, "mode=websocket");
			if (is_yes(po.tls)) push(opts, "tls");
			if (po.host != null) push(opts, "host=" + po.host);
			if (po.path != null) push(opts, "path=" + po.path);
			o.plugin = "v2ray-plugin";
		} else {
			o.plugin = plug;
		}
	} else {
		o.plugin = (plug === "obfs") ? "obfs-local" : plug;
	}
	if (length(opts)) o.plugin_opts = join(";", opts);
}

// clash_to_outbound(p) — one Clash proxy map -> one sing-box outbound (no tag;
// the caller owns tagging). Returns null for anything we cannot represent.
function clash_to_outbound(p) {
	if (type(p) !== "object") return null;
	let kind = lc(s_of(p.type));
	let server = s_of(p.server);
	let port = port_of(p);
	if (server === "" || port === 0) return null;

	let o = { server: server, server_port: port };
	let tr = clash_transport(p);
	let tls = null;

	if (kind === "ss" || kind === "shadowsocks") {
		o.type = "shadowsocks";
		o.method = s_of(p.cipher);
		o.password = s_of(p.password);
		if (o.method === "" || o.password === "") return null;
		clash_ss_plugin(p, o);
	} else if (kind === "vmess") {
		o.type = "vmess";
		o.uuid = s_of(p.uuid);
		if (o.uuid === "") return null;
		let aid = +p["alterId"];
		if (!(aid > 0)) aid = +p["alter-id"];
		if (aid > 0) o.alter_id = aid;
		let cipher = s_of(p.cipher);
		o.security = (cipher !== "") ? cipher : "auto";
		if (p["packet-encoding"] != null && p["packet-encoding"] !== "")
			o.packet_encoding = "" + p["packet-encoding"];
		tls = clash_tls(p, false);
	} else if (kind === "vless") {
		o.type = "vless";
		o.uuid = s_of(p.uuid);
		if (o.uuid === "") return null;
		if (p.flow != null && p.flow !== "") o.flow = "" + p.flow;
		if (p["packet-encoding"] != null && p["packet-encoding"] !== "")
			o.packet_encoding = "" + p["packet-encoding"];
		tls = clash_tls(p, false);
	} else if (kind === "trojan") {
		o.type = "trojan";
		o.password = s_of(p.password);
		if (o.password === "") return null;
		tls = clash_tls(p, true);
	} else if (kind === "hysteria2" || kind === "hy2") {
		o.type = "hysteria2";
		o.password = s_of(p.password ?? p.auth);
		if (p.obfs != null && p.obfs !== "") {
			let ob = { type: "" + p.obfs };
			let opw = p["obfs-password"];
			if (opw != null && opw !== "") ob.password = "" + opw;
			o.obfs = ob;
		}
		if (+p.up > 0)   o.up_mbps   = +p.up;
		if (+p.down > 0) o.down_mbps = +p.down;
		// port hopping: Clash `ports: "1000-2000,3000"` -> sing-box server_ports
		if (p.ports != null && p.ports !== "") {
			let ranges = [];
			for (let r in split("" + p.ports, ",")) {
				let t = trim(r);
				if (match(t, /^[0-9]+-[0-9]+$/)) push(ranges, t);
				else if (match(t, /^[0-9]+$/))   push(ranges, t + ":" + t);
			}
			if (length(ranges)) o.server_ports = ranges;
		}
		tls = clash_tls(p, true);
	} else if (kind === "socks5" || kind === "socks") {
		o.type = "socks";
		o.version = "5";
		if (p.username != null && p.username !== "") o.username = "" + p.username;
		if (p.password != null && p.password !== "") o.password = "" + p.password;
		tls = clash_tls(p, false);
	} else if (kind === "http" || kind === "https") {
		o.type = "http";
		if (p.username != null && p.username !== "") o.username = "" + p.username;
		if (p.password != null && p.password !== "") o.password = "" + p.password;
		tls = clash_tls(p, kind === "https");
	} else {
		return null;   // ssr, snell, wireguard, … — not representable, skip
	}

	// socks/http have no transport in sing-box; the rest do.
	if (tr && o.type !== "socks" && o.type !== "http" && o.type !== "shadowsocks" &&
	    o.type !== "hysteria2")
		o.transport = tr;
	if (tls) o.tls = tls;
	return o;
}

// -------------------------------------------------------- Xray -> sing-box
// An Xray/V2Ray config JSON: `outbounds` entries carry `protocol` +
// settings/streamSettings where sing-box has a flat `type` + fields. Panels
// hand these out verbatim as an "Xray JSON subscription"; without a translation
// the whole body parses to zero nodes, which the fetcher reads as "wrong UA"
// and rotates through every profile for nothing.

const XRAY_PROXY_PROTOS = {
	vless: true, vmess: true, trojan: true, shadowsocks: true, socks: true, http: true,
};
// Local policy outbounds every Xray config carries. Ignored, NOT counted as
// skipped: "45 nodes, 3 skipped" on a clean config is a bug report waiting to
// happen.
const XRAY_LOCAL_PROTOS = { freedom: true, blackhole: true, dns: true, loopback: true };

// xray_stream(ss, out) -> bool. Fills out.tls / out.transport. false means the
// stream is one we cannot represent (xhttp, kcp, quic, …) — skip the node
// rather than ship an outbound that silently talks plain TCP instead.
function xray_stream(ss, out) {
	if (type(ss) !== "object") return true;   // no streamSettings = plain TCP

	let sec = lc(s_of(ss.security));
	if (sec === "tls" || sec === "reality") {
		let ts = (sec === "reality") ? ss.realitySettings : ss.tlsSettings;
		if (type(ts) !== "object") ts = {};
		let t = { enabled: true };
		let sni = ts.serverName;
		if (sni != null && sni !== "") t.server_name = "" + sni;
		if (is_yes(ts.allowInsecure)) t.insecure = true;
		let alpn = alpn_of(ts.alpn);
		if (alpn) t.alpn = alpn;
		let fp = ts.fingerprint;
		if (fp != null && fp !== "" && fp !== "none")
			t.utls = { enabled: true, fingerprint: "" + fp };
		if (sec === "reality") {
			let r = { enabled: true };
			if (ts.publicKey != null && ts.publicKey !== "") r.public_key = "" + ts.publicKey;
			if (ts.shortId  != null && ts.shortId  !== "") r.short_id   = "" + ts.shortId;
			t.reality = r;
			if (!t.utls) t.utls = { enabled: true, fingerprint: "chrome" };
		}
		out.tls = t;
	}

	let net = lc(s_of(ss.network));
	if (net === "" || net === "tcp" || net === "raw") return true;   // xray 25.x renamed tcp -> raw

	if (net === "ws") {
		let o = (type(ss.wsSettings) === "object") ? ss.wsSettings : {};
		let t = { type: "ws", path: (o.path != null && o.path !== "") ? "" + o.path : "/" };
		let h = {};
		if (type(o.headers) === "object") for (let k in o.headers) h[k] = "" + o.headers[k];
		if (o.host != null && o.host !== "" && h.Host == null) h.Host = "" + o.host;
		if (length(h)) t.headers = h;
		out.transport = t;
		return true;
	}
	if (net === "grpc") {
		let o = (type(ss.grpcSettings) === "object") ? ss.grpcSettings : {};
		let t = { type: "grpc" };
		if (o.serviceName != null && o.serviceName !== "") t.service_name = "" + o.serviceName;
		out.transport = t;
		return true;
	}
	if (net === "httpupgrade") {
		let o = (type(ss.httpupgradeSettings) === "object") ? ss.httpupgradeSettings : {};
		let t = { type: "httpupgrade" };
		if (o.path != null && o.path !== "") t.path = "" + o.path;
		if (o.host != null && o.host !== "") t.host = "" + o.host;
		out.transport = t;
		return true;
	}
	if (net === "h2" || net === "http") {
		let o = (type(ss.httpSettings) === "object") ? ss.httpSettings : {};
		let t = { type: "http" };
		if (o.path != null && o.path !== "") t.path = "" + o.path;
		if (o.host != null && o.host !== "")
			t.host = (type(o.host) === "array") ? o.host : [ "" + o.host ];
		out.transport = t;
		return true;
	}
	return false;
}

// xray_to_outbound(o) — one Xray outbound -> one sing-box outbound (no tag).
// null = skip.
function xray_to_outbound(o) {
	if (type(o) !== "object") return null;
	let proto = lc(s_of(o.protocol));
	if (!XRAY_PROXY_PROTOS[proto]) return null;
	let st = (type(o.settings) === "object") ? o.settings : {};
	let out;

	if (proto === "vless" || proto === "vmess") {
		let v = (type(st.vnext) === "array") ? st.vnext[0] : null;
		if (type(v) !== "object") return null;
		let u = (type(v.users) === "array") ? v.users[0] : null;
		if (type(u) !== "object" || s_of(u.id) === "") return null;
		out = { type: proto, server: s_of(v.address), server_port: port_of(v),
		        uuid: s_of(u.id) };
		if (proto === "vless") {
			// "none" is xray's way of spelling "no flow"; sing-box rejects it.
			if (u.flow != null && u.flow !== "" && u.flow !== "none") out.flow = "" + u.flow;
		} else {
			out.alter_id = +u.alterId || 0;
			out.security = (s_of(u.security) !== "") ? s_of(u.security) : "auto";
		}
	} else {
		let srv = (type(st.servers) === "array") ? st.servers[0] : null;
		if (type(srv) !== "object") return null;
		out = { type: proto, server: s_of(srv.address), server_port: port_of(srv) };
		if (proto === "trojan") {
			if (s_of(srv.password) === "") return null;
			out.password = s_of(srv.password);
		} else if (proto === "shadowsocks") {
			if (s_of(srv.method) === "" || s_of(srv.password) === "") return null;
			out.method   = s_of(srv.method);
			out.password = s_of(srv.password);
		} else {
			let u = (type(srv.users) === "array") ? srv.users[0] : null;
			if (type(u) === "object") {
				if (s_of(u.user) !== "") out.username = s_of(u.user);
				if (s_of(u.pass) !== "") out.password = s_of(u.pass);
			}
		}
	}

	if (out.server === "" || !out.server_port) return null;
	if (!xray_stream(o.streamSettings, out)) return null;
	return out;
}

// ------------------------------------------------------------- format parsers

function nodes_from_yaml(body) {
	let nodes = [], skipped = 0;
	let proxies = [];
	try { proxies = yaml_proxies(body); } catch (_) { proxies = []; }
	for (let p in proxies) {
		let ob = null;
		try { ob = clash_to_outbound(p); } catch (_) { ob = null; }
		if (!ob) { skipped++; continue; }
		let nm = (type(p) === "object" && p.name != null && p.name !== "") ? "" + p.name : null;
		push(nodes, { outbound: ob, display_name: nm, link: null });
	}
	return { format: "clash", nodes: nodes, skipped: skipped };
}

// is_xray_list(list) — an Xray outbound has `protocol`, a sing-box one has
// `type`. One entry deciding for the whole body is fine: no panel mixes the two
// dialects in a single document.
function is_xray_list(list) {
	for (let o in list)
		if (type(o) === "object" && o.protocol != null && o.type == null) return true;
	return false;
}

function nodes_from_xray(list) {
	let nodes = [], skipped = 0;
	for (let o in list) {
		if (type(o) === "object" && XRAY_LOCAL_PROTOS[lc(s_of(o.protocol))]) continue;
		let ob = null;
		try { ob = xray_to_outbound(o); } catch (_) { ob = null; }
		if (!ob) { skipped++; continue; }
		let nm = (type(o) === "object" && o.tag != null && o.tag !== "") ? "" + o.tag : null;
		push(nodes, { outbound: ob, display_name: nm, link: null });
	}
	return { format: "xray", nodes: nodes, skipped: skipped };
}

function nodes_from_json(body) {
	let nodes = [], skipped = 0;
	let doc = null;
	try { doc = json(body); } catch (_) { doc = null; }
	let list = [];
	if (type(doc) === "array") list = doc;
	else if (type(doc) === "object" && type(doc.outbounds) === "array") list = doc.outbounds;
	else if (type(doc) === "object" && doc.type != null) list = [ doc ];
	else if (type(doc) === "object" && doc.protocol != null) list = [ doc ];
	if (is_xray_list(list)) return nodes_from_xray(list);
	for (let o in list) {
		if (type(o) !== "object" || !JSON_PROXY_TYPES[s_of(o.type)]) { skipped++; continue; }
		let nm = (o.tag != null && o.tag !== "") ? "" + o.tag : null;
		let ob = {};
		for (let k in o) if (k !== "tag") ob[k] = o[k];
		push(nodes, { outbound: ob, display_name: nm, link: null });
	}
	return { format: "singbox", nodes: nodes, skipped: skipped };
}

function nodes_from_uri_list(body) {
	let nodes = [], skipped = 0;
	for (let line in split(body, "\n")) {
		let t = trim(line);
		if (t === "" || substr(t, 0, 1) === "#" || substr(t, 0, 2) === "//") continue;
		if (!match(lc(t), /^[a-z][a-z0-9+.-]*:\/\//)) continue;
		let p = null;
		try { p = sharelink.parse_proxy_link(t); } catch (_) { p = null; }
		if (!p || !p.outbound) { skipped++; continue; }
		push(nodes, p);
	}
	return { format: "uri", nodes: nodes, skipped: skipped };
}

// detect(body) — first non-blank content decides. Deliberately cheap and in the
// spec's order: JSON, then Clash YAML, then a URI list, else base64.
function detect(body) {
	let t = trim(body);
	if (t === "") return "empty";
	let c = substr(t, 0, 1);
	if (c === "{" || c === "[") return "json";
	if (match(t, /(^|\n)[ \t]*["']?proxies["']?:/)) return "clash";
	if (index(t, "://") >= 0) return "uri";
	return "base64";
}

// parse_body(body, depth) -> { format, nodes[], skipped }. depth bounds the
// base64 unwrap: the plain case is ONE decode, and F4 ("recursive base64,
// depth 1") allows a base64 blob whose payload is itself base64 — so at most
// two. A hostile feed cannot make us decode forever.
const MAX_B64_DEPTH = 2;

function parse_body(body, depth) {
	if (body == null) return { format: "empty", nodes: [], skipped: 0 };
	let f = detect(body);
	if (f === "json")  return nodes_from_json(body);
	if (f === "clash") return nodes_from_yaml(body);
	if (f === "uri")   return nodes_from_uri_list(body);
	if (f === "base64" && (depth ?? 0) < MAX_B64_DEPTH) {
		let dec = helpers.b64_decode(body);
		if (dec != null && length(dec))
			return parse_body(dec, (depth ?? 0) + 1);
	}
	return { format: f, nodes: [], skipped: 0 };
}

// ---------------------------------------------------------- on-disk node lines

// encode_node(n) — one line of sub_<name>.txt. Share-link nodes keep their URI
// verbatim (unchanged on-disk format, still greppable); everything else becomes
// a compact JSON record.
function encode_node(n) {
	if (n.link != null && n.link !== "") return n.link;
	return sprintf("%J", { o: n.outbound, n: n.display_name, l: null });
}

// parse_node(line) — the inverse, used by lib/outbound.uc at generate time.
function parse_node(line) {
	let t = trim(line);
	if (t === "") return null;
	if (substr(t, 0, 1) !== "{") {
		let p = null;
		try { p = sharelink.parse_proxy_link(t); } catch (_) { p = null; }
		return p;
	}
	let rec = null;
	try { rec = json(t); } catch (_) { rec = null; }
	if (type(rec) !== "object" || type(rec.o) !== "object") return null;
	return { outbound: rec.o, display_name: rec.n ?? null, link: rec.l ?? null };
}

return {
	detect,
	parse_body,
	parse_node,
	encode_node,
	// test seams
	_yaml_proxies: yaml_proxies,
	_clash_to_outbound: clash_to_outbound,
	_xray_to_outbound: xray_to_outbound,
};
