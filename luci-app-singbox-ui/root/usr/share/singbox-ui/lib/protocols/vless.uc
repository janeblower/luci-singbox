// lib/protocols/vless.uc — vless outbound descriptor.
// Inbound descriptor (with multi-user support) lands in D1.5.
//
// Outbound emit is byte-equal to the legacy if-branches in
// lib/outbound.uc (build_constructor_for).

let reg = require("protocols.registry");
let helpers = require("helpers");

reg.register({
	kind: "outbound", type: "vless", sing_box_type: "vless",
	fields: [
		{ name: "server",      type: "string", required: true,
		  validate: "host", group: "basic" },
		{ name: "server_port", type: "number", required: true,
		  validate: "port", group: "basic" },
		{ name: "server_uuid", type: "string", required: true,
		  secret: true, validate: "uuid", group: "credentials", ui_label: "UUID" },
		{ name: "vless_flow",  type: "enum",
		  values: ["", "none", "xtls-rprx-vision"],
		  group: "credentials", ui_label: "Flow" },
		// NOTE: tls_* / transport_* / multiplex_* fields are intentionally
		// absent here. They are emitted by emit() via shared helpers in
		// lib/outbound.uc, and will be merged into schema_dump() output in D2.
		// Until then, reg.get("outbound","vless").fields under-reports.
	],
	emit: function(s) {
		let ob = require("outbound");
		let out = {
			type: "vless",
			tag:  s[".name"],
			server:      helpers.s_opt(s, "server"),
			server_port: helpers.s_num(s.server_port),
		};
		if (length(helpers.s_opt(s, "server_uuid"))) out.uuid = s.server_uuid;
		if (length(helpers.s_opt(s, "vless_flow")) && s.vless_flow !== "none")
			out.flow = s.vless_flow;
		let tls = ob.build_tls_client(s, "vless");
		if (tls) out.tls = tls;
		let tr = ob.build_transport(s);
		if (tr) out.transport = tr;
		let mux = ob.build_multiplex(s);
		if (mux) out.multiplex = mux;
		return out;
	},
});

return {};
