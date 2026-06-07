// lib/inbound.uc — sing-box `inbounds` array, built from `inbound` UCI sections.
// Protocol IS the kind; mode/inbound_json are legacy and silently ignored. Pure: no I/O.

// D1.5: eagerly load descriptor modules so their register() calls fire at
// module load. Inbound descriptors land incrementally in D1.5.2-D1.5.8;
// each require() is wrapped so an absent module never breaks the legacy
// switch — it just falls through to the per-type handler below.
try { require("protocols.trojan");      } catch (_) {}
try { require("protocols.shadowsocks"); } catch (_) {}
try { require("protocols.vless");       } catch (_) {}
try { require("protocols.vmess");       } catch (_) {}
try { require("protocols.hysteria2");   } catch (_) {}
try { require("protocols.tuic");        } catch (_) {}
try { require("protocols.anytls");      } catch (_) {}

let helpers = require("helpers");
const s_opt    = helpers.s_opt;
const s_bool   = helpers.s_bool;
const s_num    = helpers.s_num;
const csv_list = helpers.csv_list;
const as_array = helpers.as_array;

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
	// sing-box 1.12: vmess inbound `users[].alterId` is camelCase in the
	// wire JSON (not snake_case). The UCI field name stays `vmess_alter_id`
	// so existing configs don't break.
	if (proto === "vmess" && length(s_opt(s, "vmess_alter_id")))
		u.alterId = s_num(s.vmess_alter_id);
	// vmess inbound users do not accept a per-user `security`; the cipher
	// is selected by the client per connection. Field omitted.
	return u;
}

// build_inbound_users(s, proto) — parse `list inbound_user` entries for
// vmess/vless. Returns an array of user objects, or [] when no valid
// entries.  Format per entry:
//   vmess: "name:uuid"          or "name:uuid:alterId"
//   vless: "name:uuid"          or "name:uuid:flow"
// Invalid entries (missing name/uuid) are silently skipped.
function build_inbound_users(s, proto) {
	let entries = as_array(s.inbound_user);
	let out = [];
	for (let entry in entries) {
		let parts = split(entry, ":");
		if (length(parts) < 2) continue;
		let name = parts[0], uuid = parts[1];
		if (!length(name) || !length(uuid)) continue;
		let u = { name: name, uuid: uuid };
		if (length(parts) >= 3 && length(parts[2])) {
			if (proto === "vmess") {
				let aid = +parts[2];
				u.alterId = aid || 0;
			} else if (proto === "vless") {
				if (parts[2] !== "none") u.flow = parts[2];
			}
		}
		push(out, u);
	}
	return out;
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
		let alpn = as_array(s.tls_alpn);
		if (length(alpn)) tls.alpn = alpn;
		if (s_bool(s, "tls_insecure")) tls.insecure = true;
		if (length(s_opt(s, "utls_fingerprint")))
			tls.utls = { enabled: true, fingerprint: s.utls_fingerprint };
	} else if (sec === "reality") {
		let r = { enabled: true };
		if (length(s_opt(s, "reality_private_key"))) r.private_key = s.reality_private_key;
		// sing-box 1.12: tls.reality.short_id is a single hex string (0-8 chars),
		// not an array. (sing-box.sagernet.org/configuration/shared/tls/)
		if (length(s_opt(s, "reality_short_id")))    r.short_id    = s.reality_short_id;
		let hs = {};
		if (length(s_opt(s, "reality_handshake_server")))
			hs.server = s.reality_handshake_server;
		if (length(s_opt(s, "reality_handshake_server_port")))
			hs.server_port = s_num(s.reality_handshake_server_port);
		if (length(keys(hs))) r.handshake = hs;
		tls.reality = r;
	}
	// ECH (server-side): key/key_path are server-only.
	// pq_signature_schemes_enabled is deprecated in 1.12 and removed in 1.13 — never emitted.
	if (s_bool(s, "tls_ech")) {
		let ech = { enabled: true };
		let key = as_array(s.tls_ech_key);
		if (length(key)) ech.key = key;
		if (length(s_opt(s, "tls_ech_key_path"))) ech.key_path = s.tls_ech_key_path;
		tls.ech = ech;
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

function build_one(s) {
	// D1.5: consult protocol registry first. Inbound sections discriminate
	// by `protocol` (not `type`); we mirror the legacy default-to-tproxy
	// fallback below. If a descriptor is registered for the resolved
	// proto, use its emit() and skip the legacy switch.
	try {
		let reg = require("protocols.registry");
		let proto_lookup = s_opt(s, "protocol");
		if (proto_lookup) {
			let d = reg.get("inbound", proto_lookup);
			if (d != null) return d.emit(s);
		}
	} catch (_) { /* registry not available — fall through to legacy switch */ }

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
		};
		let users = [];
		let entries = as_array(s.ss_user);
		// Limitation: the on-the-wire entry format is `name:password`, with
		// `:` as the sole field separator. A password containing a literal
		// colon is split at the FIRST colon — anything after the second
		// colon is silently dropped. Operators who need ':' in a password
		// must base64-encode it (and document the encoding alongside the
		// section) or pick a colon-free passphrase. A future migration to
		// a TSV / JSON entry format would lift this restriction. Mirrored
		// in docs/uci-schema.md → inbound shadowsocks section.
		for (let entry in entries) {
			let colon = index(entry, ":");
			if (colon < 1) continue;  // malformed (empty name or no colon)
			let name = substr(entry, 0, colon);
			let pw   = substr(entry, colon + 1);
			if (!length(name) || !length(pw)) continue;
			push(users, { name: name, password: pw });
		}
		if (length(users)) {
			ob.users = users;
		} else if (length(s_opt(s, "server_password"))) {
			ob.password = s.server_password;
		}
		let net = s_opt(s, "network");
		if (net === "udp" || net === "tcp") ob.network = net;
		let mux = build_multiplex(s);
		if (mux) ob.multiplex = mux;
	} else if (proto === "vless" || proto === "vmess" || proto === "trojan" || proto === "hysteria2") {
		ob = { type: proto, tag: tag, listen: listen, listen_port: port };
		// vmess/vless support a `list inbound_user` multi-user mode. When
		// non-empty, the section-level single-user fields (server_uuid,
		// vmess_alter_id, vless_flow) are dropped — sing-box rejects both
		// at once.  trojan/hysteria2 stay single-user for this phase.
		let multi = (proto === "vmess" || proto === "vless")
			? build_inbound_users(s, proto)
			: [];
		ob.users = length(multi) ? multi : [ build_user(s) ];
		if (proto === "hysteria2") {
			let ob_type = s_opt(s, "hysteria2_obfs_type") || "none";
			// 1.12: only "salamander" is defined; "gecko" lands in 1.14.
			if (ob_type !== "none" && length(s_opt(s, "hysteria2_obfs_password")))
				ob.obfs = { type: ob_type, password: s.hysteria2_obfs_password };
			if (length(s_opt(s, "up_mbps")))   ob.up_mbps   = s_num(s.up_mbps);
			if (length(s_opt(s, "down_mbps"))) ob.down_mbps = s_num(s.down_mbps);
			if (length(s_opt(s, "hysteria2_masquerade")))
				ob.masquerade = s.hysteria2_masquerade;
			if (s_bool(s, "brutal_debug")) ob.brutal_debug = true;
			if (s_bool(s, "ignore_client_bandwidth")) ob.ignore_client_bandwidth = true;
		}
		let tls = build_tls(s);
		if (tls) ob.tls = tls;
		if (proto !== "hysteria2") {
			let tr = build_transport(s);
			if (tr) ob.transport = tr;
			let mux = build_multiplex(s);
			if (mux) ob.multiplex = mux;
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

return { build_inbounds, build_one, build_user, build_inbound_users,
         build_tls, build_transport, build_multiplex };
