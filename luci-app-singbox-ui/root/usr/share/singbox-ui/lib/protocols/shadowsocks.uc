// lib/protocols/shadowsocks.uc — shadowsocks outbound + inbound descriptors.
// Inbound descriptor (with multi-user `ss_user` support) added in D1.5.3.
//
// Outbound emit is byte-equal to the legacy if-branches in
// lib/outbound.uc (build_constructor_for). No TLS, no transport,
// no multiplex on the outbound side.

let reg = require("protocols.registry");
let helpers = require("helpers");

reg.register({
	kind: "outbound", type: "shadowsocks", sing_box_type: "shadowsocks",
	fields: [
		{ name: "server",             type: "string", required: true,
		  validate: "host", group: "basic" },
		{ name: "server_port",        type: "number", required: true,
		  validate: "port", group: "basic" },
		{ name: "server_password",    type: "string", required: true,
		  secret: true, group: "credentials", ui_label: "Password" },
		// "none" is for plugin-chain setups; plugin/plugin_opts themselves
		// are out-of-scope (see docs/protocol-coverage.md).
		{ name: "shadowsocks_method", type: "enum",
		  values: ["aes-128-gcm", "aes-256-gcm", "chacha20-ietf-poly1305",
		           "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm",
		           "2022-blake3-chacha20-poly1305", "none"],
		  group: "credentials", ui_label: "Method" },
		// NOTE: shadowsocks outbound has no tls/transport/multiplex; these
		// are NOT shared UI groups for this protocol. Inbound (D1.5) DOES
		// get a multiplex block.
	],
	emit: function(s) {
		let out = {
			type: "shadowsocks",
			tag: s[".name"],
			server: helpers.s_opt(s, "server"),
			server_port: helpers.s_num(s.server_port),
		};
		if (length(helpers.s_opt(s, "server_password"))) out.password = s.server_password;
		out.method = helpers.s_opt(s, "shadowsocks_method") || "aes-128-gcm";
		return out;
	},
});

reg.register({
	kind: "inbound", type: "shadowsocks", sing_box_type: "shadowsocks",
	fields: [
		{ name: "listen",             type: "string", default: "::", group: "basic",
		  ui_label: "Listen address" },
		{ name: "listen_port",        type: "number", required: true,
		  validate: "port", group: "basic", ui_label: "Listen port" },
		{ name: "shadowsocks_method", type: "enum",
		  values: ["aes-128-gcm", "aes-256-gcm", "chacha20-ietf-poly1305",
		           "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm",
		           "2022-blake3-chacha20-poly1305", "none"],
		  group: "credentials", ui_label: "Method" },
		// ss_user: list of "name:password" entries; multi-user mode.
		// When non-empty, server_password fallback is ignored.
		// secret:true masks the whole list value in D3 scrub (no granular
		// secret_items — D1.5 simplification).
		{ name: "ss_user",            type: "list", item: "user_record:shadowsocks",
		  secret: true, group: "credentials", ui_label: "Users (name:password)" },
		{ name: "server_password",    type: "string", secret: true,
		  group: "credentials", ui_label: "Single-user password (fallback)" },
		{ name: "network",            type: "enum",
		  values: ["", "tcp", "udp"], group: "advanced", ui_label: "Network" },
		// NOTE: multiplex_* fields surfaced via shared UI; emitted by
		// emit() via inb.build_multiplex(). Merged into schema_dump() in D2.
	],
	emit: function(s) {
		let inb = require("inbound");
		let port = helpers.s_num(s.listen_port);
		if (!port) {
			warn(sprintf("inbound.uc: missing listen_port for '%s'; skipping\n", s[".name"]));
			return null;
		}
		let out = {
			type: "shadowsocks",
			tag: s[".name"],
			listen: length(helpers.s_opt(s, "listen")) ? s.listen : "::",
			listen_port: port,
			method: helpers.s_opt(s, "shadowsocks_method") || "aes-128-gcm",
		};
		// Multi-user via ss_user list. Each entry: "name:password" (first colon splits).
		// A password containing a literal colon is split at the FIRST colon only.
		// Mirrored in docs/uci-schema.md → inbound shadowsocks section.
		let users = [];
		let entries = helpers.as_array(s.ss_user);
		for (let entry in entries) {
			let colon = index(entry, ":");
			if (colon < 1) continue;  // malformed (empty name or no colon)
			let name = substr(entry, 0, colon);
			let pw   = substr(entry, colon + 1);
			if (!length(name) || !length(pw)) continue;
			push(users, { name: name, password: pw });
		}
		if (length(users)) {
			out.users = users;
		} else if (length(helpers.s_opt(s, "server_password"))) {
			out.password = s.server_password;
		}
		let net = helpers.s_opt(s, "network");
		if (net === "udp" || net === "tcp") out.network = net;
		let mux = inb.build_multiplex(s);
		if (mux) out.multiplex = mux;
		return out;
	},
});

return {};
