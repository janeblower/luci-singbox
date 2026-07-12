// lib/sharelink.uc — share-link / subscription URL parsers for outbound
// proxies. Extracted from lib/outbound.uc (SRP, S4-10): this module owns the
// untrusted-string handling (url-decode, control-char scrub, host/port/tag
// whitelists, base64) and the per-scheme parsers; outbound.uc owns the
// UCI→JSON dispatch and re-exports parse_proxy_url for back-compat.
//
// All parsers return a sing-box outbound object or null on parse failure.
// Hostile sources must not be able to inject control bytes or arbitrary tags
// (see drop_ctrl / safe_tag / safe_host).

let helpers = require("helpers");
let smap = require("sharelink_map");
const fnv1a32 = helpers.fnv1a32;

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
	// S4.2: a bracketed IPv6 literal ([::1]) must be stored WITHOUT brackets —
	// sing-box's `server` field wants the bare address; a bracketed value is
	// rejected. Strip them here so every parser (which captures host with the
	// brackets) gets the canonical form.
	let bm = match(raw, /^\[([0-9a-fA-F:]+)\]$/);
	if (bm) return bm[1];                               // [IPv6] -> IPv6
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
		// S1.4/4.4: decode the KEY too — a producer that percent-encodes a key
		// (e.g. %73ni=) would otherwise be stored under the literal "%73ni" and
		// the lookup (params["sni"]) would silently miss it.
		let k = url_decode(substr(part, 0, eq));
		let v = substr(part, eq + 1);
		params[k] = url_decode(v);
	}
	return params;
}

// h_tls_security(params, host, out) — build the whole TLS block for a vless link.
// Consumes security/sni/peer/pbk/sid/fp/alpn/allowInsecure/insecure (SPEC Delegated).
//
// TLS is enabled when `security` says so — but ALSO, when `security` is absent,
// whenever the link carries a TLS-only parameter (sni/alpn/fp/pbk). Providers
// routinely ship such links; requiring security= made us connect in plaintext to
// a TLS server, i.e. not connect at all.
//
// Reality: the sub-block is emitted ONLY when pbk is present — a reality block
// without public_key makes sing-box FATAL at config load. `security=reality`
// without pbk therefore degrades to plain TLS here (forkop rejects the link
// outright; the softer behaviour is deliberate and pinned by a test).
function h_tls_security(params, host, out) {
	let sec = params["security"] ?? "";
	let sni = length(params["sni"]) ? params["sni"] : (params["peer"] ?? "");
	let pbk = params["pbk"] ?? "";
	let fp  = smap.normalize_fp(params["fp"] ?? "");
	let alpn = smap.alpn_for_transport(smap.coerce(params["alpn"], "csv") ?? [],
	                                   params["type"] ?? "");
	// reality (and a bare pbk) always speaks uTLS; chrome is the universal default.
	if ((sec === "reality" || length(pbk)) && !length(fp)) fp = "chrome";

	let on = (sec === "tls" || sec === "xtls" || sec === "reality") ||
	         (!length(sec) && (length(sni) || length(alpn) || length(fp) || length(pbk)));
	if (!on) return;

	out.tls = { enabled: true, server_name: length(sni) ? sni : host };
	if (smap.is_true(params["allowInsecure"]) || smap.is_true(params["insecure"]))
		out.tls.insecure = true;
	if (length(alpn)) out.tls.alpn = alpn;
	if (length(fp))   out.tls.utls = { enabled: true, fingerprint: fp };
	if (length(pbk)) {
		out.tls.reality = { enabled: true, public_key: pbk };
		if (length(params["sid"])) out.tls.reality.short_id = params["sid"];
	}
}

// ---- xhttp (Xray) transport --------------------------------------------------
// The knobs arrive either flat in the query (camel or snake) or nested inside a
// JSON `extra` blob (?extra={...}, extra.xhttpSettings, extra.downloadSettings.
// xhttpSettings, and an `extra` key inside either). Both spellings, all nesting
// levels, one flat lookup table.

const XHTTP_KEYS = [
	"xPaddingBytes", "x_padding_bytes", "noGRPCHeader", "no_grpc_header",
	"scMaxEachPostBytes", "sc_max_each_post_bytes",
	"scMinPostsIntervalMs", "sc_min_posts_interval_ms",
	"scStreamUpServerSecs", "sc_stream_up_server_secs", "xmux",
];

function x_present(v) { return v != null && !(type(v) === "string" && v === ""); }

// x_obj(v) — an object as-is; a JSON string parsed; anything else {}.
function x_obj(v) {
	if (type(v) === "object") return v;
	if (!x_present(v)) return {};
	try { let p = json(`${v}`); return (type(p) === "object") ? p : {}; }
	catch (e) { return {}; }
}

function x_copy(dst, src) {
	if (type(src) !== "object") return;
	for (let k in XHTTP_KEYS) if (x_present(src[k])) dst[k] = src[k];
}

function x_extra(params) {
	let dst = {};
	let e = x_obj(params["extra"]);
	x_copy(dst, e);
	let xs = x_obj(e.xhttpSettings);
	x_copy(dst, xs);
	x_copy(dst, x_obj(xs.extra));
	let ds = x_obj(x_obj(e.downloadSettings).xhttpSettings);
	x_copy(dst, ds);
	x_copy(dst, x_obj(ds.extra));
	return dst;
}

// x_val — flat query wins over the extra blob; camel wins over snake.
function x_val(params, extra, camel, snake) {
	for (let v in [ params[camel], params[snake], extra[camel], extra[snake] ])
		if (x_present(v)) return v;
	return null;
}

function x_int(v, positive) {
	let n;
	if (type(v) === "int") n = v;
	else if (type(v) === "double") { n = int(v); if (n != v) return null; }
	else {
		let s = trim(`${v ?? ""}`);
		if (!match(s, /^[0-9]+$/)) return null;
		n = +s;
	}
	if (type(n) !== "int" || n < 0) return null;
	if (positive && n === 0) return null;
	return n;
}

// x_range(v) — an int, a "N-M" range string, or a {from,to} object. Returns the
// int, the canonical "N-M" string, or {from,to}; null when it is none of those.
function x_range(v, positive) {
	if (!x_present(v)) return null;
	if (type(v) === "object") {
		let f = x_int(v.from, positive), t = x_int(v.to, positive);
		return (f != null && t != null && f <= t) ? { from: f, to: t } : null;
	}
	let n = x_int(v, positive);
	if (n != null) return n;
	let mm = match(trim(`${v}`), /^([0-9]+)-([0-9]+)$/);
	if (!mm) return null;
	let f = x_int(mm[1], positive), t = x_int(mm[2], positive);
	return (f != null && t != null && f <= t) ? sprintf("%d-%d", f, t) : null;
}

function x_xmux(v) {
	// `src`, not `s`: the uci-schema coverage guard reads `s.<field>` as a UCI
	// field access, and xmux keys are sing-box JSON, not UCI.
	let src = x_obj(v);
	let r = {};
	for (let p in [ [ "max_concurrency", "maxConcurrency" ],
	                [ "max_connections", "maxConnections" ],
	                [ "c_max_reuse_times", "cMaxReuseTimes" ],
	                [ "h_max_request_times", "hMaxRequestTimes" ],
	                [ "h_max_reusable_secs", "hMaxReusableSecs" ] ]) {
		let n = x_range(x_present(src[p[1]]) ? src[p[1]] : src[p[0]], false);
		if (n != null) r[p[0]] = n;
	}
	let ka = x_int(x_present(src.hKeepAlivePeriod) ? src.hKeepAlivePeriod : src.h_keep_alive_period, false);
	if (ka != null) r.h_keep_alive_period = ka;
	return length(keys(r)) ? r : null;
}

function h_xhttp(params, path, host) {
	let mode = params["mode"] ?? "auto";
	if (mode !== "auto" && mode !== "packet-up" && mode !== "stream-up" && mode !== "stream-one")
		mode = "auto";
	let tr = {
		type: "xhttp", mode: mode,
		path: length(path) ? path : "/",
		x_padding_bytes: "100-1000",
		no_grpc_header: false,
		sc_max_each_post_bytes: 1000000,
		sc_min_posts_interval_ms: 30,
	};
	let h = length(host) ? host : (params["sni"] ?? "");   // xhttp Host falls back to sni
	if (length(h)) tr.host = h;

	let ex = x_extra(params);
	let v = x_range(x_val(params, ex, "xPaddingBytes", "x_padding_bytes"), true);
	if (v != null) tr.x_padding_bytes = v;
	v = x_val(params, ex, "noGRPCHeader", "no_grpc_header");
	if (x_present(v)) tr.no_grpc_header = smap.is_true(v);
	v = x_range(x_val(params, ex, "scMaxEachPostBytes", "sc_max_each_post_bytes"), true);
	if (v != null) tr.sc_max_each_post_bytes = v;
	v = x_range(x_val(params, ex, "scMinPostsIntervalMs", "sc_min_posts_interval_ms"), false);
	if (v != null) tr.sc_min_posts_interval_ms = v;
	v = x_range(x_val(params, ex, "scStreamUpServerSecs", "sc_stream_up_server_secs"), false);
	if (v != null) tr.sc_stream_up_server_secs = v;
	let xm = x_xmux(x_val(params, ex, "xmux", "xmux"));
	if (xm) tr.xmux = xm;
	return tr;
}

// h_transport(params, out) — v2ray/xhttp transport block.
// Consumes type/path/host/serviceName/ed + the xhttp keys (SPEC Delegated).
function h_transport(params, out) {
	let tt = params["type"];
	if (!length(tt) || tt === "tcp") return;
	let path = params["path"] ?? "";
	let host = params["host"] ?? "";
	let tr;
	if (tt === "ws") {
		// A ws server without an explicit path serves "/" — the omitted path
		// used to make sing-box request the empty path and get a 404.
		tr = { type: "ws", path: length(path) ? path : "/" };
		if (length(host)) tr.headers = { Host: host };
		let ed = smap.coerce(params["ed"], "int");
		if (ed != null) tr.max_early_data = ed;
	} else if (tt === "grpc") {
		tr = { type: "grpc" };
		let sn = length(params["serviceName"]) ? params["serviceName"] : path;
		if (length(sn)) tr.service_name = sn;
	} else if (tt === "http" || tt === "h2") {
		tr = { type: "http" };
		if (length(path)) tr.path = path;
		let hosts = smap.coerce(host, "csv");   // http host is a LIST (may be a CSV)
		if (hosts != null) tr.host = hosts;
	} else if (tt === "httpupgrade") {
		tr = { type: "httpupgrade" };
		if (length(path)) tr.path = path;
		if (length(host)) tr.host = host;
	} else if (tt === "xhttp") {
		tr = h_xhttp(params, path, host);
	} else {
		tr = { type: tt };
	}
	out.transport = tr;
}

function parse_vless(url) {
	// vless://uuid@host:port[/]?params#name  (the trailing slash before the query
	// is legal — and common; rejecting it dropped whole provider subscriptions.)
	let m = match(url, /^vless:\/\/([^@]+)@(\[[0-9a-fA-F:]+\]|[^:/?#]+):([0-9]+)\/?(\?[^#]*)?(#.*)?$/);
	if (!m) return null;
	let uuid = url_decode(m[1]);
	let host = safe_host(m[2]);
	let port = safe_port(m[3]);
	if (!length(uuid) || !host || !port) return null;
	let params = m[4] ? parse_query(substr(m[4], 1)) : {};
	// S4.3: capture the #fragment node name as the tag (consistent with
	// ss/trojan), instead of silently discarding it.
	let frag = m[5] ? url_decode(substr(m[5], 1)) : null;

	// flow: sing-box only knows xtls-rprx-vision. Anything else is an Xray-only
	// flow whose traffic sing-box cannot produce — importing it would build a
	// config that silently fails to connect, so reject the link.
	let flow = params["flow"] ?? "";
	if (length(flow) && flow !== "xtls-rprx-vision") return null;

	let out = {
		type: "vless", server: host, server_port: port, uuid: uuid,
		tag: safe_tag(length(frag) ? frag : host, url),
	};
	h_tls_security(params, host, out);   // Delegated: the TLS block
	h_transport(params, out);            // Delegated: the transport block
	if (length(flow) && out.tls != null) out.flow = flow;   // flow is TLS-only
	smap.apply_params(params, smap.SPEC.vless, out);  // Direct: packetEncoding/encryption
	return out;
}

// h_obfs(params, out) — hysteria2 salamander obfuscation block.
// Consumes the `obfs`/`obfs-password` params (SPEC Delegated).
function h_obfs(params, out) {
	if (params["obfs"] === "salamander" && length(params["obfs-password"]))
		out.obfs = { type: "salamander", password: params["obfs-password"] };
}

// h_ports(spec) — hysteria2 port hopping. "1000-2000,443" (from ?mport= or from
// the port position itself) becomes sing-box's server_ports ["1000:2000","443:443"].
// Returns null when the spec names a single port (the caller then emits the plain
// server_port) or when any entry is not a valid port / range.
// Consumes the `mport` param (SPEC Delegated).
function h_ports(spec) {
	let v = trim(`${spec ?? ""}`);
	if (index(v, ",") < 0 && index(v, "-") < 0) return null;
	let out = [];
	for (let e in split(v, ",")) {
		let entry = trim(e);
		let mm = match(entry, /^([0-9]+)-([0-9]+)$/);
		let a, b;
		if (mm) {
			a = safe_port(mm[1]); b = safe_port(mm[2]);
			if (!a || !b || a > b) return null;
		} else {
			a = safe_port(entry);
			if (!a) return null;
			b = a;
		}
		push(out, sprintf("%d:%d", a, b));
	}
	return length(out) ? out : null;
}

function parse_hy2(url) {
	// The port position accepts a hop spec ("443-8443", "443,8000-9000") as well
	// as a plain port; ?mport= overrides it.
	let m = match(url, /^hy2:\/\/([^@]+)@(\[[0-9a-fA-F:]+\]|[^:/?#]+):([0-9][0-9,\-]*)\/?(\?[^#]*)?(#.*)?$/) ||
			match(url, /^hysteria2:\/\/([^@]+)@(\[[0-9a-fA-F:]+\]|[^:/?#]+):([0-9][0-9,\-]*)\/?(\?[^#]*)?(#.*)?$/);
	if (!m) return null;
	let password = url_decode(m[1]);
	let host = safe_host(m[2]);
	if (!length(password) || !host) return null;
	let params = m[4] ? parse_query(substr(m[4], 1)) : {};
	let frag = m[5] ? url_decode(substr(m[5], 1)) : null;

	let spec = length(params["mport"]) ? params["mport"] : m[3];
	let ports = h_ports(spec);
	let port = ports ? null : safe_port(spec);
	if (!ports && !port) return null;

	let out = {
		type: "hysteria2", server: host, password: password,
		tag: safe_tag(length(frag) ? frag : host, url),
		tls: { enabled: true, server_name: length(params["sni"]) ? params["sni"] : host },
	};
	if (ports) out.server_ports = ports;
	else       out.server_port  = port;
	h_obfs(params, out);
	smap.apply_params(params, smap.SPEC.hysteria2, out);
	return out;
}

// parse_tuic(url) — TUIC v5 share-link: tuic://<uuid>:<password>@host:port?params#name
function parse_tuic(url) {
	let m = match(url, /^tuic:\/\/([^@]+)@(\[[0-9a-fA-F:]+\]|[^:/?#]+):([0-9]+)\/?(\?[^#]*)?(#.*)?$/);
	if (!m) return null;
	let userinfo = url_decode(m[1]);
	let host = safe_host(m[2]);
	let port = safe_port(m[3]);
	if (!host || !port) return null;
	let colon = index(userinfo, ":");
	if (colon < 0) return null;                       // tuic needs uuid:password
	let uuid = substr(userinfo, 0, colon);
	let password = substr(userinfo, colon + 1);
	if (!length(uuid) || !length(password)) return null;
	let params = m[4] ? parse_query(substr(m[4], 1)) : {};
	let frag = m[5] ? url_decode(substr(m[5], 1)) : null;
	let out = {
		type: "tuic", server: host, server_port: port,
		uuid: uuid, password: password,
		tag: safe_tag(length(frag) ? frag : host, url),
		tls: { enabled: true, server_name: length(params["sni"]) ? params["sni"] : host },
	};
	smap.apply_params(params, smap.SPEC.tuic, out);
	return out;
}

// parse_anytls(url) — AnyTLS share-link: anytls://<password>@host:port?params#name
// (userinfo "user:pass" form: the password is the part after ':', else the whole).
function parse_anytls(url) {
	let m = match(url, /^anytls:\/\/([^@]+)@(\[[0-9a-fA-F:]+\]|[^:/?#]+):([0-9]+)\/?(\?[^#]*)?(#.*)?$/);
	if (!m) return null;
	let userinfo = url_decode(m[1]);
	let host = safe_host(m[2]);
	let port = safe_port(m[3]);
	if (!host || !port) return null;
	let colon = index(userinfo, ":");
	let password = (colon >= 0) ? substr(userinfo, colon + 1) : userinfo;
	if (!length(password)) return null;
	let params = m[4] ? parse_query(substr(m[4], 1)) : {};
	let frag = m[5] ? url_decode(substr(m[5], 1)) : null;
	let out = {
		type: "anytls", server: host, server_port: port, password: password,
		tag: safe_tag(length(frag) ? frag : host, url),
		tls: { enabled: true, server_name: length(params["sni"]) ? params["sni"] : host },
	};
	smap.apply_params(params, smap.SPEC.anytls, out);
	return out;
}

// b64_decode(s) — tolerant base64 decoder for share-link payloads. The real
// implementation now lives in helpers.b64_decode (shared with subscription.uc
// so the two decode paths can't drift). This stays a thin local alias so the
// file-private call sites and the definition-order constraint documented below
// (parse_socks etc. call it) remain intact.
function b64_decode(s) { return helpers.b64_decode(s); }

// parse_socks(url) — SOCKS share-link: socks[4|4a|5]://[user:pass@]host:port#name
// userinfo is OPTIONAL: plain "user:pass" or base64("user:pass").
// The scheme carries the version: socks4 -> "4", socks4a -> "4a", socks5/socks -> "5".
// Placed after b64_decode: ucode resolves top-level function refs by definition
// order, so parse_socks (which calls b64_decode) must follow it.
function parse_socks(url) {
	let host, port, params, frag, raw = null;
	// Pattern A: with userinfo  (m[1]=userinfo m[2]=host m[3]=port m[4]=query m[5]=frag)
	let m = match(url, /^socks[0-9a-z]*:\/\/([^@]+)@(\[[0-9a-fA-F:]+\]|[^:/?#]+):([0-9]+)\/?(\?[^#]*)?(#.*)?$/);
	if (m) {
		raw  = m[1];
		host = safe_host(m[2]); port = safe_port(m[3]);
		params = m[4] ? parse_query(substr(m[4], 1)) : {};
		frag   = m[5] ? url_decode(substr(m[5], 1)) : null;
	} else {
		// Pattern B: no userinfo  (m[1]=host m[2]=port m[3]=query m[4]=frag).
		// Host class adds @ to its negation so this only matches a true no-@ URL.
		m = match(url, /^socks[0-9a-z]*:\/\/(\[[0-9a-fA-F:]+\]|[^:/?#@]+):([0-9]+)\/?(\?[^#]*)?(#.*)?$/);
		if (!m) return null;
		host = safe_host(m[1]); port = safe_port(m[2]);
		params = m[3] ? parse_query(substr(m[3], 1)) : {};
		frag   = m[4] ? url_decode(substr(m[4], 1)) : null;
	}
	if (!host || !port) return null;
	let username = null, password = null;
	if (length(raw)) {
		let ui = url_decode(raw);
		let colon = index(ui, ":");
		if (colon < 0) {                              // maybe base64("user:pass")?
			let dec = b64_decode(raw);                // decode the ORIGINAL raw, not url_decoded
			if (dec != null) {
				let decd = drop_ctrl(dec);
				let dc = index(decd, ":");
				// Only adopt the decoded form if it actually yields user:pass —
				// a colon-less userinfo (e.g. "justuser") can be valid base64 yet
				// decode to junk; in that case keep the literal raw as username.
				if (dc >= 0) { ui = decd; colon = dc; }
			}
		}
		if (colon >= 0) {
			username = substr(ui, 0, colon);
			password = substr(ui, colon + 1);
			// socks4 links commonly repeat the user in the password slot; a
			// password identical to the username is noise, not a credential.
			if (username === password) password = null;
		} else if (length(ui)) {
			username = ui;
		}
	}
	let vm = match(url, /^socks([0-9a-z]*):/);   // "" | "4" | "4a" | "5"
	let out = {
		type: "socks", server: host, server_port: port,
		version: length(vm[1]) ? vm[1] : "5",
		tag: safe_tag(length(frag) ? frag : host, url),
	};
	if (length(username)) out.username = username;
	if (length(password)) out.password = password;
	smap.apply_params(params, smap.SPEC.socks, out);
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
	let query = "";   // S9.3: SIP002 ?plugin=... query, captured below

	let at = index(body, "@");
	if (at >= 0) {
		// Could be plain (method:password@host:port[?...]) or legacy with
		// base64(method:password)@host:port[?...].
		let userinfo = substr(body, 0, at);
		let tail = substr(body, at + 1);

		// Tail: host:port[?query]
		let q = index(tail, "?");
		let hp = q >= 0 ? substr(tail, 0, q) : tail;
		if (q >= 0) query = substr(tail, q + 1);
		let hpm = match(hp, /^(\[[0-9a-fA-F:]+\]|[^:]+):([0-9]+)\/?$/);
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
		if (q >= 0) query = substr(tail, q + 1);
		let hpm = match(hp, /^(\[[0-9a-fA-F:]+\]|[^:]+):([0-9]+)\/?$/);
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
	// S9.3: SIP002 ?plugin=name;opt=val;... → sing-box plugin / plugin_opts.
	// The plugin value's first ';'-segment is the plugin name; the remainder is
	// the opts string — UNLESS the link carries the opts in its own
	// ?plugin-opts= param, in which case `plugin` is the bare name.
	// parse_query splits on the first '=' only, so an unencoded (or %-encoded)
	// ';'/'=' inside the value survives intact.
	// SPEC ss: plugin + plugin-opts, handler "ss_plugin" — split below.
	if (length(query)) {
		let q = parse_query(query);
		let pl = q["plugin"] ?? "";
		let po = q["plugin-opts"] ?? "";
		if (length(pl) && !length(po)) {
			let semi = index(pl, ";");
			if (semi >= 0) {
				po = substr(pl, semi + 1);
				pl = substr(pl, 0, semi);
			}
		}
		if (length(pl)) out.plugin = pl;
		if (length(po)) out.plugin_opts = po;
	}
	return out;
}

// parse_trojan(url) — trojan-GFW share-link.
//   trojan://<password>@<host>:<port>[?sni=...&type=ws&path=...&allowInsecure=1][#name]
// Returns a sing-box trojan outbound object, or null on parse failure.
function parse_trojan(url) {
	let m = match(url, /^trojan:\/\/([^@]+)@(\[[0-9a-fA-F:]+\]|[^:/?#]+):([0-9]+)\/?(\?[^#]*)?(#.*)?$/);
	if (!m) return null;
	let password = url_decode(m[1]);
	let host = safe_host(m[2]);
	let port = safe_port(m[3]);
	if (!length(password) || !host || !port) return null;
	let params = m[4] ? parse_query(substr(m[4], 1)) : {};
	let frag = m[5] ? url_decode(substr(m[5], 1)) : null;
	let out = {
		type: "trojan",
		tag: safe_tag(length(frag) ? frag : host, url),
		server: host, server_port: port, password: password,
		tls: { enabled: true, server_name: host },   // trojan is always TLS
	};
	h_transport(params, out);
	smap.apply_params(params, smap.SPEC.trojan, out);
	return out;
}

// parse_hysteria1(url) — Hysteria v1 share-link: hysteria://host:port?auth=...&...#name
// (auth may also appear in userinfo). Maps to a sing-box hysteria outbound.
function parse_hysteria1(url) {
	// Hysteria v1: hysteria:// or hy:// with optional userinfo (auth token).
	// Try with-userinfo pattern first (groups: [1]=userinfo [2]=host [3]=port [4]=query [5]=frag).
	let m = match(url, /^hysteria:\/\/([^@]+)@(\[[0-9a-fA-F:]+\]|[^:/?#]+):([0-9]+)\/?(\?[^#]*)?(#.*)?$/) ||
	        match(url, /^hy:\/\/([^@]+)@(\[[0-9a-fA-F:]+\]|[^:/?#]+):([0-9]+)\/?(\?[^#]*)?(#.*)?$/);
	let userauth = null;
	let host, port, params, frag;
	if (m) {
		userauth = url_decode(m[1]);
		host  = safe_host(m[2]);
		port  = safe_port(m[3]);
		params = m[4] ? parse_query(substr(m[4], 1)) : {};
		frag  = m[5] ? url_decode(substr(m[5], 1)) : null;
	} else {
		// No userinfo — groups: [1]=host [2]=port [3]=query [4]=frag.
		let m2 = match(url, /^hysteria:\/\/(\[[0-9a-fA-F:]+\]|[^:/?#@]+):([0-9]+)\/?(\?[^#]*)?(#.*)?$/) ||
		         match(url, /^hy:\/\/(\[[0-9a-fA-F:]+\]|[^:/?#@]+):([0-9]+)\/?(\?[^#]*)?(#.*)?$/);
		if (!m2) return null;
		host  = safe_host(m2[1]);
		port  = safe_port(m2[2]);
		params = m2[3] ? parse_query(substr(m2[3], 1)) : {};
		frag  = m2[4] ? url_decode(substr(m2[4], 1)) : null;
	}
	if (!host || !port) return null;
	// auth may be in userinfo (hysteria://TOKEN@host) or the ?auth= param.
	if (length(userauth) && !length(params["auth"])) params["auth"] = userauth;
	let out = {
		type: "hysteria", server: host, server_port: port,
		tag: safe_tag(length(frag) ? frag : host, url),
		tls: { enabled: true, server_name: length(params["peer"]) ? params["peer"] : host },
	};
	smap.apply_params(params, smap.SPEC.hysteria, out);
	return out;
}

// parse_vmess(url) — VMess share-link (v2rayN format): vmess://base64(json).
// The decoded JSON is the v2rayN node object {v,ps,add,port,id,aid,net,type,
// host,path,tls,sni,scy}. Mapped to a sing-box vmess outbound. S9.4.
function parse_vmess(url) {
	let dec = b64_decode(substr(url, 8));   // after "vmess://"
	if (dec == null) return null;
	let cfg;
	try { cfg = json(drop_ctrl(dec)); } catch (e) { return null; }
	if (type(cfg) !== "object") return null;

	let host = safe_host(`${cfg.add ?? ""}`);
	let port = safe_port(cfg.port);
	let uuid = drop_ctrl(`${cfg.id ?? ""}`);
	if (!host || !port || !length(uuid)) return null;

	let scy = drop_ctrl(`${cfg.scy ?? ""}`);
	let out = {
		type: "vmess", server: host, server_port: port, uuid: uuid,
		security: length(scy) ? scy : "auto",
		alter_id: +(cfg.aid ?? 0) || 0,
		tag: safe_tag(drop_ctrl(`${cfg.ps ?? ""}`), url),
	};

	let net = drop_ctrl(`${cfg.net ?? "tcp"}`);
	let wpath = drop_ctrl(`${cfg.path ?? ""}`);
	let whost = drop_ctrl(`${cfg.host ?? ""}`);
	if (net === "ws") {
		let tr = { type: "ws", path: length(wpath) ? wpath : "/" };
		if (length(whost)) tr.headers = { Host: whost };
		out.transport = tr;
	} else if (net === "grpc") {
		out.transport = { type: "grpc" };
		if (length(wpath)) out.transport.service_name = wpath;
	} else if (net === "h2" || net === "http") {
		out.transport = { type: "http" };
		if (length(wpath)) out.transport.path = wpath;
		let hosts = smap.coerce(whost, "csv");   // http host is a LIST
		if (hosts != null) out.transport.host = hosts;
	}

	if (drop_ctrl(`${cfg.tls ?? ""}`) === "tls") {
		let sni = drop_ctrl(`${cfg.sni ?? ""}`);
		if (!length(sni)) sni = length(whost) ? whost : host;
		out.tls = { enabled: true, server_name: sni };
	}
	// Direct SPEC pass (alpn/fp onto the tls block). vmess params == the decoded
	// v2rayN JSON object; apply_params reads it the same as a query map. The
	// gate {tls:"tls"} ensures alpn/fp only attach when TLS is enabled.
	// `net` rides along so the alpn transform can apply the per-transport rule
	// (ws/httpupgrade -> http/1.1) — apply_params reads type ?? net.
	let vparams = {
		tls:  drop_ctrl(`${cfg.tls ?? ""}`),
		alpn: drop_ctrl(`${cfg.alpn ?? ""}`),
		fp:   drop_ctrl(`${cfg.fp ?? ""}`),
		net:  net,
	};
	smap.apply_params(vparams, smap.SPEC.vmess, out);
	return out;
}

// display_name_of(url) — the RAW UTF-8 node name a human sees: the #fragment
// (percent-decoded, control chars scrubbed) or, for vmess, the `ps` field of
// the base64 JSON body. Deliberately NOT run through safe_tag: emoji/Cyrillic
// names ("🇳🇱 Умная локация") must survive intact. This never reaches the
// sing-box JSON — it goes to the outbound-meta side-car (lib/outbound.uc) and
// is rendered by the UI as untrusted content (E()/textContent only).
// Placed after b64_decode: ucode resolves top-level function refs by definition
// order.
function display_name_of(url) {
	if (match(url, /^vmess:\/\//)) {
		let dec = b64_decode(substr(url, 8));
		if (dec == null) return null;
		let cfg;
		try { cfg = json(drop_ctrl(dec)); } catch (e) { return null; }
		if (type(cfg) !== "object") return null;
		let ps = drop_ctrl(`${cfg.ps ?? ""}`);
		return length(ps) ? ps : null;
	}
	// Every other scheme puts the name in the trailing #fragment; the parsers'
	// regexes treat the FIRST '#' as its start (query is [^#]*), so do the same.
	let h = index(url, "#");
	if (h < 0) return null;
	let n = url_decode(substr(url, h + 1));
	return length(n) ? n : null;
}

// country_from_flag_emoji(name) — providers prefix node names with a flag
// ("🇳🇱 Amsterdam"); a flag is two regional-indicator code points (U+1F1E6..
// U+1F1FF) that spell the ISO-3166 alpha-2 code. ucode strings are BYTES, so
// scan the UTF-8 encoding directly: F0 9F 87 A6 ('A') .. F0 9F 87 BF ('Z').
// Truncated/garbage UTF-8 just fails the byte test -> null, never throws.
function flag_letter(s, i) {
	if (ord(s, i) != 0xF0 || ord(s, i + 1) != 0x9F || ord(s, i + 2) != 0x87) return null;
	let b = ord(s, i + 3);
	if (b == null || b < 0xA6 || b > 0xBF) return null;
	return chr(65 + b - 0xA6);
}
function country_from_flag_emoji(name) {
	if (type(name) !== "string") return null;
	for (let i = 0; i + 8 <= length(name); i++) {
		let a = flag_letter(name, i);
		if (a == null) continue;
		let b = flag_letter(name, i + 4);
		if (b != null) return a + b;
	}
	return null;
}

// content_tag(o) — stable, ASCII-safe tag suffix derived from what the node IS
// (protocol + endpoint + credential), not from where it sits in the
// subscription. A provider reordering its node list used to renumber every
// sub_<i> tag, silently moving the user's selector pick onto a different
// server; hashing the content instead keeps the tag pinned to the node across
// refreshes. Callers namespace it (`<section>__<hash>`) and resolve the
// (rare, identical-node) collisions.
function content_tag(o) {
	if (o == null) return null;
	return fnv1a32(sprintf("%s|%s|%s|%s|%s|%s",
		o.type ?? "", o.server ?? "", o.server_port ?? "",
		o.uuid ?? "", o.password ?? "", o.method ?? ""));
}

function parse_proxy_url(url) {
	if (match(url, /^vless:\/\//))     return parse_vless(url);
	if (match(url, /^vmess:\/\//))     return parse_vmess(url);
	if (match(url, /^ss:\/\//))        return parse_ss(url);
	if (match(url, /^trojan:\/\//))    return parse_trojan(url);
	if (match(url, /^hy2:\/\//) ||
	    match(url, /^hysteria2:\/\//)) return parse_hy2(url);
	if (match(url, /^tuic:\/\//))      return parse_tuic(url);
	if (match(url, /^hysteria:\/\//) ||
	    match(url, /^hy:\/\//))        return parse_hysteria1(url);
	if (match(url, /^anytls:\/\//))    return parse_anytls(url);
	if (match(url, /^socks5?:\/\//) ||
	    match(url, /^socks4a?:\/\//)) return parse_socks(url);
	warn("sharelink.uc: unsupported proxy URL scheme: " + url + "\n");
	return null;
}

// parse_proxy_link(url) — the full parse result: the sing-box outbound (tag =
// safe_tag, ASCII), the human-readable display_name (raw UTF-8, may be null)
// and the originating link (for the dashboard's copy-link button).
// parse_proxy_url stays the outbound-only entry point every existing caller
// (json_raw descriptor, export_section, tests) already uses.
// Defined after parse_proxy_url — definition order is resolution order.
function parse_proxy_link(url) {
	let ob = parse_proxy_url(url);
	if (!ob) return null;
	return { outbound: ob, display_name: display_name_of(url), link: url };
}

// The per-scheme parsers and sanitisers stay file-private — they are reached
// solely through parse_proxy_url's dispatch above.
return {
	parse_proxy_url,
	parse_proxy_link,
	display_name_of,
	content_tag,
	country_from_flag_emoji,
};
