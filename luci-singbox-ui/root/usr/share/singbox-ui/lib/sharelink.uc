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

// h_tls_security(params, host, out) — enable the TLS block for security=tls|reality
// and seed server_name (sni param wins, else the host). For reality, assemble the
// reality sub-block (public_key + short_id) ONLY when pbk is present — emitting a
// reality block without public_key makes sing-box FATAL at config load.
// Consumes the `security`/`sni`/`pbk`/`sid` params (SPEC Delegated).
function h_tls_security(params, host, out) {
	let sec = params["security"];
	if (sec !== "tls" && sec !== "reality") return;
	out.tls = { enabled: true, server_name: length(params["sni"]) ? params["sni"] : host };
	if (sec === "reality" && length(params["pbk"])) {
		out.tls.reality = { enabled: true, public_key: params["pbk"] };
		if (length(params["sid"])) out.tls.reality.short_id = params["sid"];
	}
}

// h_transport(params, out) — v2ray transport block from type/path/host/serviceName.
// Consumes the `type`/`path`/`host`/`serviceName` params (SPEC Delegated).
function h_transport(params, out) {
	let tt = params["type"];
	if (!length(tt) || tt === "tcp") return;
	let tr = { type: (tt === "h2") ? "http" : tt };
	if (tt === "ws") {
		if (length(params["path"])) tr.path = params["path"];
		if (length(params["host"])) tr.headers = { Host: params["host"] };
	} else if (tt === "grpc") {
		if (length(params["serviceName"])) tr.service_name = params["serviceName"];
		else if (length(params["path"]))   tr.service_name = params["path"];
	} else if (tt === "http" || tt === "h2") {
		if (length(params["path"])) tr.path = params["path"];
		if (length(params["host"])) tr.host = [ params["host"] ];
	} else if (tt === "httpupgrade") {
		if (length(params["path"])) tr.path = params["path"];
		if (length(params["host"])) tr.host = params["host"];
	}
	out.transport = tr;
}

function parse_vless(url) {
	// vless://uuid@host:port?params#name
	let m = match(url, /^vless:\/\/([^@]+)@(\[[0-9a-fA-F:]+\]|[^:/?#]+):([0-9]+)(\?[^#]*)?(#.*)?$/);
	if (!m) return null;
	let uuid = url_decode(m[1]);
	let host = safe_host(m[2]);
	let port = safe_port(m[3]);
	if (!length(uuid) || !host || !port) return null;
	let params = m[4] ? parse_query(substr(m[4], 1)) : {};
	// S4.3: capture the #fragment node name as the tag (consistent with
	// ss/trojan), instead of silently discarding it.
	let frag = m[5] ? url_decode(substr(m[5], 1)) : null;
	let out = {
		type: "vless", server: host, server_port: port, uuid: uuid,
		tag: safe_tag(length(frag) ? frag : host, url),
	};
	h_tls_security(params, host, out);   // Delegated: security + sni
	h_transport(params, out);            // Delegated: type/path/host/serviceName
	smap.apply_params(params, smap.SPEC.vless, out);  // Direct: flow/fp/pbk/sid/alpn/insecure
	return out;
}

// h_obfs(params, out) — hysteria2 salamander obfuscation block.
// Consumes the `obfs`/`obfs-password` params (SPEC Delegated).
function h_obfs(params, out) {
    if (params["obfs"] === "salamander" && length(params["obfs-password"]))
        out.obfs = { type: "salamander", password: params["obfs-password"] };
}

function parse_hy2(url) {
    let m = match(url, /^hy2:\/\/([^@]+)@(\[[0-9a-fA-F:]+\]|[^:/?#]+):([0-9]+)(\?[^#]*)?(#.*)?$/) ||
            match(url, /^hysteria2:\/\/([^@]+)@(\[[0-9a-fA-F:]+\]|[^:/?#]+):([0-9]+)(\?[^#]*)?(#.*)?$/);
    if (!m) return null;
    let password = url_decode(m[1]);
    let host = safe_host(m[2]);
    let port = safe_port(m[3]);
    if (!length(password) || !host || !port) return null;
    let params = m[4] ? parse_query(substr(m[4], 1)) : {};
    let frag = m[5] ? url_decode(substr(m[5], 1)) : null;
    let out = {
        type: "hysteria2", server: host, server_port: port, password: password,
        tag: safe_tag(length(frag) ? frag : host, url),
        tls: { enabled: true, server_name: length(params["sni"]) ? params["sni"] : host },
    };
    h_obfs(params, out);
    smap.apply_params(params, smap.SPEC.hysteria2, out);
    return out;
}

// parse_tuic(url) — TUIC v5 share-link: tuic://<uuid>:<password>@host:port?params#name
function parse_tuic(url) {
	let m = match(url, /^tuic:\/\/([^@]+)@(\[[0-9a-fA-F:]+\]|[^:/?#]+):([0-9]+)(\?[^#]*)?(#.*)?$/);
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
	let m = match(url, /^anytls:\/\/([^@]+)@(\[[0-9a-fA-F:]+\]|[^:/?#]+):([0-9]+)(\?[^#]*)?(#.*)?$/);
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

// parse_socks(url) — SOCKS5 share-link: socks5://[user:pass@]host:port#name
// userinfo is OPTIONAL: plain "user:pass" or base64("user:pass"). -> sing-box socks (v5).
// Placed after b64_decode: ucode resolves top-level function refs by definition
// order, so parse_socks (which calls b64_decode) must follow it.
function parse_socks(url) {
	let host, port, params, frag, raw = null;
	// Pattern A: with userinfo  (m[1]=userinfo m[2]=host m[3]=port m[4]=query m[5]=frag)
	let m = match(url, /^socks5?:\/\/([^@]+)@(\[[0-9a-fA-F:]+\]|[^:/?#]+):([0-9]+)(\?[^#]*)?(#.*)?$/);
	if (m) {
		raw  = m[1];
		host = safe_host(m[2]); port = safe_port(m[3]);
		params = m[4] ? parse_query(substr(m[4], 1)) : {};
		frag   = m[5] ? url_decode(substr(m[5], 1)) : null;
	} else {
		// Pattern B: no userinfo  (m[1]=host m[2]=port m[3]=query m[4]=frag).
		// Host class adds @ to its negation so this only matches a true no-@ URL.
		m = match(url, /^socks5?:\/\/(\[[0-9a-fA-F:]+\]|[^:/?#@]+):([0-9]+)(\?[^#]*)?(#.*)?$/);
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
		if (colon < 0) {                              // try base64(user:pass)
			let dec = b64_decode(raw);                // decode the ORIGINAL raw, not url_decoded
			if (dec != null) { ui = drop_ctrl(dec); colon = index(ui, ":"); }
		}
		if (colon >= 0) {
			username = substr(ui, 0, colon);
			password = substr(ui, colon + 1);
		} else if (length(ui)) {
			username = ui;
		}
	}
	let out = {
		type: "socks", server: host, server_port: port, version: "5",
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
		let hpm = match(hp, /^(\[[0-9a-fA-F:]+\]|[^:]+):([0-9]+)$/);
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
		let hpm = match(hp, /^(\[[0-9a-fA-F:]+\]|[^:]+):([0-9]+)$/);
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
	// the opts string. parse_query splits on the first '=' only, so an
	// unencoded (or %-encoded) ';'/'=' inside the value survives intact.
	// SPEC ss: { param:"plugin", handler:"ss_plugin" } — bespoke name;opts split below
	if (length(query)) {
		let pl = parse_query(query)["plugin"];
		if (length(pl)) {
			let semi = index(pl, ";");
			out.plugin = (semi >= 0) ? substr(pl, 0, semi) : pl;
			if (semi >= 0 && semi + 1 < length(pl))
				out.plugin_opts = substr(pl, semi + 1);
		}
	}
	return out;
}

// parse_trojan(url) — trojan-GFW share-link.
//   trojan://<password>@<host>:<port>[?sni=...&type=ws&path=...&allowInsecure=1][#name]
// Returns a sing-box trojan outbound object, or null on parse failure.
function parse_trojan(url) {
	let m = match(url, /^trojan:\/\/([^@]+)@(\[[0-9a-fA-F:]+\]|[^:/?#]+):([0-9]+)(\?[^#]*)?(#.*)?$/);
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
	let m = match(url, /^hysteria:\/\/([^@]+)@(\[[0-9a-fA-F:]+\]|[^:/?#]+):([0-9]+)(\?[^#]*)?(#.*)?$/) ||
	        match(url, /^hy:\/\/([^@]+)@(\[[0-9a-fA-F:]+\]|[^:/?#]+):([0-9]+)(\?[^#]*)?(#.*)?$/);
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
		let m2 = match(url, /^hysteria:\/\/(\[[0-9a-fA-F:]+\]|[^:/?#@]+):([0-9]+)(\?[^#]*)?(#.*)?$/) ||
		         match(url, /^hy:\/\/(\[[0-9a-fA-F:]+\]|[^:/?#@]+):([0-9]+)(\?[^#]*)?(#.*)?$/);
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
		let tr = { type: "ws" };
		if (length(wpath)) tr.path = wpath;
		if (length(whost)) tr.headers = { Host: whost };
		out.transport = tr;
	} else if (net === "grpc") {
		out.transport = { type: "grpc" };
		if (length(wpath)) out.transport.service_name = wpath;
	} else if (net === "h2" || net === "http") {
		out.transport = { type: "http" };
		if (length(wpath)) out.transport.path = wpath;
		if (length(whost)) out.transport.host = [ whost ];
	}

	if (drop_ctrl(`${cfg.tls ?? ""}`) === "tls") {
		let sni = drop_ctrl(`${cfg.sni ?? ""}`);
		if (!length(sni)) sni = length(whost) ? whost : host;
		out.tls = { enabled: true, server_name: sni };
	}
	// Direct SPEC pass (alpn/fp onto the tls block). vmess params == the decoded
	// v2rayN JSON object; apply_params reads it the same as a query map. The
	// gate {tls:"tls"} ensures alpn/fp only attach when TLS is enabled.
	let vparams = {
		tls:  drop_ctrl(`${cfg.tls ?? ""}`),
		alpn: drop_ctrl(`${cfg.alpn ?? ""}`),
		fp:   drop_ctrl(`${cfg.fp ?? ""}`),
	};
	smap.apply_params(vparams, smap.SPEC.vmess, out);
	return out;
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
	if (match(url, /^socks5?:\/\//))   return parse_socks(url);
	warn("sharelink.uc: unsupported proxy URL scheme: " + url + "\n");
	return null;
}

// Only parse_proxy_url is consumed externally (outbound.uc re-export). The
// per-scheme parsers and sanitisers stay file-private — they are reached
// solely through parse_proxy_url's dispatch below.
return {
	parse_proxy_url,
};
