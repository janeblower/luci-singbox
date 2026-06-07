// lib/protocols/vmess.uc — vmess outbound + inbound descriptors.
//
// Inbound descriptor (with multi-user inbound_user support) added in D1.5.5.
//
// Outbound emit is byte-equal to the legacy if-branches in
// lib/outbound.uc (build_constructor_for).

let reg = require("protocols.registry");
let helpers = require("helpers");

reg.register({
	kind: "outbound", type: "vmess", sing_box_type: "vmess",
	fields: [
		{ name: "server",          type: "string", required: true,
		  validate: "host", group: "basic" },
		{ name: "server_port",     type: "number", required: true,
		  validate: "port", group: "basic" },
		{ name: "server_uuid",     type: "string", required: true,
		  secret: true, validate: "uuid", group: "credentials", ui_label: "UUID" },
		{ name: "vmess_alter_id",  type: "number",
		  group: "credentials", ui_label: "Alter ID" },
		{ name: "vmess_security",  type: "enum",
		  values: ["auto", "none", "aes-128-gcm", "chacha20-poly1305"],
		  group: "credentials", ui_label: "Security" },
		// NOTE: tls_* / transport_* / multiplex_* fields are intentionally
		// absent here. They are emitted by emit() via shared helpers in
		// lib/outbound.uc, and will be merged into schema_dump() output in D2.
		// Until then, reg.get("outbound","vmess").fields under-reports.
	],
	emit: function(s) {
		let ob = require("outbound");
		let out = {
			type: "vmess",
			tag:  s[".name"],
			server:      helpers.s_opt(s, "server"),
			server_port: helpers.s_num(s.server_port),
		};
		if (length(helpers.s_opt(s, "server_uuid"))) out.uuid = s.server_uuid;
		if (length(helpers.s_opt(s, "vmess_alter_id"))) out.alter_id = helpers.s_num(s.vmess_alter_id);
		if (length(helpers.s_opt(s, "vmess_security"))) out.security = s.vmess_security;
		let tls = ob.build_tls_client(s, "vmess");
		if (tls) out.tls = tls;
		let tr = ob.build_transport(s);
		if (tr) out.transport = tr;
		let mux = ob.build_multiplex(s);
		if (mux) out.multiplex = mux;
		return out;
	},
});

reg.register({
	kind: "inbound", type: "vmess", sing_box_type: "vmess",
	fields: [
		{ name: "listen",      type: "string", default: "::", group: "basic",
		  ui_label: "Listen address" },
		{ name: "listen_port", type: "number", required: true,
		  validate: "port", group: "basic", ui_label: "Listen port" },
		// inbound_user: list of "name:uuid[:alterId]" entries; multi-user mode.
		// When non-empty, single-user fields (server_uuid, vmess_alter_id) are dropped.
		{ name: "inbound_user", type: "list", item: "user_record:vmess",
		  secret: true, group: "credentials",
		  ui_label: "Users (name:uuid[:alterId])" },
		{ name: "server_uuid",    type: "string", secret: true,
		  validate: "uuid", group: "credentials", ui_label: "UUID (single-user)" },
		{ name: "vmess_alter_id", type: "number",
		  group: "credentials", ui_label: "Alter ID" },
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
			type: "vmess",
			tag:  s[".name"],
			listen: length(helpers.s_opt(s, "listen")) ? s.listen : "::",
			listen_port: port,
		};
		let multi = inb.build_inbound_users(s, "vmess");
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
