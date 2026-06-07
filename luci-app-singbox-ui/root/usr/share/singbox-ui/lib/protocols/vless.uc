// lib/protocols/vless.uc — vless outbound + inbound descriptors.
//
// Inbound descriptor (with multi-user inbound_user support) added in D1.5.4.
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

reg.register({
	kind: "inbound", type: "vless", sing_box_type: "vless",
	fields: [
		{ name: "listen",       type: "string", default: "::", group: "basic",
		  ui_label: "Listen address" },
		{ name: "listen_port",  type: "number", required: true,
		  validate: "port", group: "basic", ui_label: "Listen port" },
		// inbound_user: list of "name:uuid[:flow]" entries; multi-user mode.
		// When non-empty, single-user fields (server_uuid, vless_flow) are dropped.
		{ name: "inbound_user", type: "list", item: "user_record:vless",
		  secret: true, group: "credentials", ui_label: "Users (name:uuid[:flow])" },
		{ name: "server_uuid",  type: "string", secret: true,
		  validate: "uuid", group: "credentials", ui_label: "UUID (single-user)" },
		{ name: "vless_flow",   type: "enum", values: ["", "none", "xtls-rprx-vision"],
		  group: "credentials", ui_label: "Flow" },
		// NOTE: tls_* / transport_* / multiplex_* surfaced via shared UI;
		// emitted by emit() via inb.build_tls/transport/multiplex. Merged
		// into schema_dump() in D2.
	],
	emit: function(s) {
		let inb = require("inbound");
		let port = helpers.s_num(s.listen_port);
		if (!port) {
			warn(sprintf("inbound.uc: missing listen_port for '%s'; skipping\n", s[".name"]));
			return null;
		}
		let out = {
			type: "vless",
			tag:  s[".name"],
			listen: length(helpers.s_opt(s, "listen")) ? s.listen : "::",
			listen_port: port,
		};
		let multi = inb.build_inbound_users(s, "vless");
		out.users = length(multi) ? multi : [ inb.build_user(s) ];
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
