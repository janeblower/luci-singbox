// lib/protocols/trojan.uc — trojan outbound descriptor.
// Inbound descriptor lands in D1.5.
//
// Outbound emit is byte-equal to the legacy if-branches in
// lib/outbound.uc (build_constructor_for).

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
		// tls_* / transport_* / multiplex_* fields are surfaced via shared
		// UI tabs and emitted via shared helpers in lib/outbound.uc.
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

return {};
