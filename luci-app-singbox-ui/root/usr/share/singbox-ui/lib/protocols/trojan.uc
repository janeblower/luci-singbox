// lib/protocols/trojan.uc — trojan outbound + inbound descriptors.
//
// Outbound emit is byte-equal to the legacy if-branches in
// lib/outbound.uc (build_constructor_for).
// Inbound emit is byte-equal to the legacy trojan branch in
// lib/inbound.uc (build_one) — D1.5.2.

let reg = require("protocols.registry");
let helpers = require("helpers");

reg.register({
	kind: "outbound", type: "trojan", sing_box_type: "trojan",
	fields: [
		{ name: "server",          type: "string", required: true,
		  validate: "host", group: "basic" },
		{ name: "server_port",     type: "number", required: true,
		  validate: "port", group: "basic" },
		{ name: "server_password", type: "string", required: true,
		  secret: true, group: "credentials", ui_label: "Password" },
		// NOTE: tls_* / transport_* / multiplex_* fields are intentionally
		// absent here. They are emitted by emit() via shared helpers in
		// lib/outbound.uc, and will be merged into schema_dump() output in D2.
		// Until then, reg.get("outbound","trojan").fields under-reports.
	],
	emit: function(s) {
		let ob = require("outbound");
		let out = {
			type: "trojan",
			tag:  s[".name"],
			server:      helpers.s_opt(s, "server"),
			server_port: helpers.s_num(s.server_port),
		};
		if (length(helpers.s_opt(s, "server_password"))) out.password = s.server_password;
		let tls = ob.build_tls_client(s, "trojan");
		if (tls) out.tls = tls;
		let tr = ob.build_transport(s);
		if (tr) out.transport = tr;
		let mux = ob.build_multiplex(s);
		if (mux) out.multiplex = mux;
		return out;
	},
});

reg.register({
	kind: "inbound", type: "trojan", sing_box_type: "trojan",
	fields: [
		{ name: "listen",        type: "string",  default: "::",
		  group: "basic",       ui_label: "Listen address" },
		{ name: "listen_port",   type: "number",  required: true,
		  validate: "port",     group: "basic",   ui_label: "Listen port" },
		{ name: "user_name",     type: "string",  group: "credentials",
		  ui_label: "User name" },
		{ name: "server_password", type: "string", required: true, secret: true,
		  group: "credentials", ui_label: "Password" },
		// NOTE: tls_* / transport_* / multiplex_* fields are intentionally
		// absent here. They are emitted by emit() via shared helpers in
		// lib/inbound.uc, and will be merged into schema_dump() output in D2.
	],
	emit: function(s) {
		let inb = require("inbound");
		let port = helpers.s_num(s.listen_port);
		if (!port) {
			warn(sprintf("inbound.uc: missing listen_port for '%s'; skipping\n", s[".name"]));
			return null;
		}
		let out = {
			type: "trojan",
			tag:  s[".name"],
			listen: length(helpers.s_opt(s, "listen")) ? s.listen : "::",
			listen_port: port,
			users: [ inb.build_user(s) ],
		};
		let tls = inb.build_tls(s);
		if (tls) out.tls = tls;
		let tr = inb.build_transport(s);
		if (tr) out.transport = tr;
		let mux = inb.build_multiplex(s);
		if (mux) out.multiplex = mux;
		return out;
	},
});

return {};
