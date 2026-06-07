// lib/protocols/shadowsocks.uc — shadowsocks outbound descriptor.
// Inbound descriptor (with multi-user `ss_user` support) lands in D1.5.
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

return {};
