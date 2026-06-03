// lib/inbound.uc — sing-box `inbounds` array, built from `inbound` UCI sections.
// Protocol IS the kind; mode/inbound_json are legacy and silently ignored. Pure: no I/O.

function s_opt(s, k) { let v = s[k]; return (v == null) ? "" : v; }
function s_bool(s, k) { return s[k] === "1"; }
function s_num(v) { let n = +v; return n || 0; }

// csv_list("a, b ,c") -> ["a","b","c"]; "" -> []
function csv_list(v) {
	if (v == null || v === "") return [];
	let out = [];
	for (let p in split(v, ",")) { let t = trim(p); if (length(t)) push(out, t); }
	return out;
}

// build_user(s) — single-user object for vless/vmess/trojan/hysteria2.
function build_user(s) {
	let proto = s.protocol;
	let u = { name: s[".name"] };
	if (proto === "vless" || proto === "vmess") {
		if (length(s_opt(s, "server_uuid"))) u.uuid = s.server_uuid;
	}
	if (proto === "trojan" || proto === "hysteria2") {
		if (length(s_opt(s, "server_password"))) u.password = s.server_password;
	}
	if (proto === "vless" && length(s_opt(s, "vless_flow")) && s.vless_flow !== "none")
		u.flow = s.vless_flow;
	if (proto === "vmess")
		u.alterId = s_num(s.vmess_alter_id);
	return u;
}

// build_tls(s) — null when security=none. hysteria2 forces tls.
function build_tls(s) {
	let sec = s_opt(s, "security") || "none";
	if (s.protocol === "hysteria2") sec = "tls";
	if (sec === "none") return null;
	let tls = { enabled: true };
	if (length(s_opt(s, "tls_server_name"))) tls.server_name = s.tls_server_name;
	if (sec === "tls") {
		if (length(s_opt(s, "tls_certificate_path"))) tls.certificate_path = s.tls_certificate_path;
		if (length(s_opt(s, "tls_key_path")))         tls.key_path         = s.tls_key_path;
		let alpn = csv_list(s_opt(s, "tls_alpn"));
		if (length(alpn)) tls.alpn = alpn;
	} else if (sec === "reality") {
		let r = { enabled: true };
		if (length(s_opt(s, "reality_private_key"))) r.private_key = s.reality_private_key;
		if (length(s_opt(s, "reality_short_id")))    r.short_id    = [ s.reality_short_id ];
		let hs = {};
		if (length(s_opt(s, "reality_handshake_server")))
			hs.server = s.reality_handshake_server;
		if (length(s_opt(s, "reality_handshake_server_port")))
			hs.server_port = s_num(s.reality_handshake_server_port);
		if (length(keys(hs))) r.handshake = hs;
		tls.reality = r;
	}
	return tls;
}

// build_transport(s) — null when transport=none. vless/vmess/trojan only.
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

function build_one(s) {
	let tag = s[".name"];
	// mode/inbound_json are legacy; protocol IS the kind (mode is ignored).
	let proto = s_opt(s, "protocol") || "tproxy";
	let listen = length(s_opt(s, "listen")) ? s.listen : "::";
	let port = s_num(s.listen_port);
	if (proto !== "tun" && !port) {
		warn(sprintf("inbound.uc: missing listen_port for '%s'; skipping\n", tag));
		return null;
	}
	let ob = null;

	if (proto === "tproxy") {
		ob = { type: "tproxy", tag: tag, listen: listen, listen_port: port };
		if (s_bool(s, "tcp_fast_open")) ob.tcp_fast_open = true;
		if (s_bool(s, "udp_fragment"))  ob.udp_fragment  = true;
	} else if (proto === "tun") {
		ob = {
			type: "tun", tag: tag,
			interface_name: s_opt(s, "interface_name") || "singbox-tun",
			mtu: s_num(s.mtu) || 9000,
			stack: s_opt(s, "stack") || "mixed",
		};
		let addr = [];
		if (length(s_opt(s, "inet4_address"))) push(addr, s.inet4_address);
		if (length(s_opt(s, "inet6_address"))) push(addr, s.inet6_address);
		if (length(addr)) ob.address = addr;
		if (s_bool(s, "auto_route"))   ob.auto_route = true;
		if (s_bool(s, "strict_route")) ob.strict_route = true;
	} else if (proto === "shadowsocks") {
		ob = {
			type: "shadowsocks", tag: tag, listen: listen, listen_port: port,
			method: s_opt(s, "shadowsocks_method") || "aes-128-gcm",
			password: s_opt(s, "server_password"),
		};
	} else if (proto === "vless" || proto === "vmess" || proto === "trojan" || proto === "hysteria2") {
		ob = { type: proto, tag: tag, listen: listen, listen_port: port };
		ob.users = [ build_user(s) ];
		if (proto === "hysteria2") {
			let ob_type = s_opt(s, "hysteria2_obfs_type") || "none";
			if (ob_type !== "none" && length(s_opt(s, "hysteria2_obfs_password")))
				ob.obfs = { type: ob_type, password: s.hysteria2_obfs_password };
			if (length(s_opt(s, "up_mbps")))   ob.up_mbps   = s_num(s.up_mbps);
			if (length(s_opt(s, "down_mbps"))) ob.down_mbps = s_num(s.down_mbps);
		}
		let tls = build_tls(s);
		if (tls) ob.tls = tls;
		if (proto !== "hysteria2") {
			let tr = build_transport(s);
			if (tr) ob.transport = tr;
		}
	} else if (proto === "direct") {
		ob = { type: "direct", tag: tag, listen: listen, listen_port: port };
		let net = s_opt(s, "network");
		if (net === "udp" || net === "tcp") ob.network = net;
		// "" or other values omit `network` (sing-box treats absence as tcp+udp).
	} else {
		warn(sprintf("inbound.uc: unknown protocol '%s' for '%s'; skipping\n", proto, tag));
		return null;
	}

	return ob;
}

function build_inbounds(cur) {
	let inbounds = [];
	cur.foreach("singbox-ui", "inbound", function(s) {
		if (s.enabled === "0") return;
		let ob = build_one(s);
		if (ob) push(inbounds, ob);
	});
	return inbounds;
}

return { build_inbounds };
