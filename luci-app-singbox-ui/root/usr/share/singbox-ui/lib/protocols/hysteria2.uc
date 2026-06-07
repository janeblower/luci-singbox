// lib/protocols/hysteria2.uc — hysteria2 outbound + inbound descriptors.
// Inbound descriptor (single-user) added in D1.5.6.
//
// Outbound emit is byte-equal to the legacy if-branches in
// lib/outbound.uc (build_constructor_for).

let reg = require("protocols.registry");
let helpers = require("helpers");

reg.register({
	kind: "outbound", type: "hysteria2", sing_box_type: "hysteria2",
	fields: [
		{ name: "server",                type: "string", required: true,
		  validate: "host", group: "basic" },
		{ name: "server_port",           type: "number", required: true,
		  validate: "port", group: "basic" },
		{ name: "server_password",       type: "string", required: true,
		  secret: true, group: "credentials", ui_label: "Password" },
		{ name: "hysteria2_obfs_type",   type: "enum",
		  values: ["none", "salamander"], group: "advanced", ui_label: "Obfs type" },
		{ name: "hysteria2_obfs_password", type: "string",
		  secret: true, group: "credentials", ui_label: "Obfs password" },
		{ name: "up_mbps",               type: "number",
		  group: "advanced", ui_label: "Up Mbps" },
		{ name: "down_mbps",             type: "number",
		  group: "advanced", ui_label: "Down Mbps" },
		{ name: "hysteria2_masquerade",  type: "string",
		  group: "advanced", ui_label: "Masquerade" },
		{ name: "brutal_debug",          type: "bool",
		  group: "advanced", ui_label: "Brutal debug" },
		{ name: "network",               type: "enum",
		  values: ["", "tcp", "udp"], group: "advanced", ui_label: "Network" },
		// NOTE: tls_* fields are intentionally absent here. They are emitted
		// by emit() via the shared build_tls_client() helper in lib/outbound.uc,
		// and will be merged into schema_dump() output in D2.
		// Until then, reg.get("outbound","hysteria2").fields under-reports.
	],
	emit: function(s) {
		let ob = require("outbound");
		let out = {
			type:        "hysteria2",
			tag:         s[".name"],
			server:      helpers.s_opt(s, "server"),
			server_port: helpers.s_num(s.server_port),
		};
		if (length(helpers.s_opt(s, "server_password"))) out.password = s.server_password;
		let ot = helpers.s_opt(s, "hysteria2_obfs_type") || "none";
		// 1.12: only "salamander" is defined; "gecko" lands in 1.14.
		if (ot !== "none" && length(helpers.s_opt(s, "hysteria2_obfs_password")))
			out.obfs = { type: ot, password: s.hysteria2_obfs_password };
		if (length(helpers.s_opt(s, "up_mbps")))   out.up_mbps   = helpers.s_num(s.up_mbps);
		if (length(helpers.s_opt(s, "down_mbps"))) out.down_mbps = helpers.s_num(s.down_mbps);
		if (length(helpers.s_opt(s, "hysteria2_masquerade")))
			out.masquerade = s.hysteria2_masquerade;
		if (helpers.s_bool(s, "brutal_debug")) out.brutal_debug = true;
		if (length(helpers.s_opt(s, "network")) && (s.network === "tcp" || s.network === "udp"))
			out.network = s.network;
		let tls = ob.build_tls_client(s, "hysteria2");
		if (tls) out.tls = tls;
		return out;
	},
});

reg.register({
	kind: "inbound", type: "hysteria2", sing_box_type: "hysteria2",
	fields: [
		{ name: "listen",                   type: "string", default: "::",
		  group: "basic", ui_label: "Listen address" },
		{ name: "listen_port",              type: "number", required: true,
		  validate: "port", group: "basic", ui_label: "Listen port" },
		{ name: "server_password",          type: "string", required: true,
		  secret: true, group: "credentials", ui_label: "Password" },
		{ name: "hysteria2_obfs_type",      type: "enum", values: ["none", "salamander"],
		  group: "advanced", ui_label: "Obfs type" },
		{ name: "hysteria2_obfs_password",  type: "string", secret: true,
		  group: "credentials", ui_label: "Obfs password" },
		{ name: "up_mbps",                  type: "number",
		  group: "advanced", ui_label: "Up Mbps" },
		{ name: "down_mbps",                type: "number",
		  group: "advanced", ui_label: "Down Mbps" },
		{ name: "hysteria2_masquerade",     type: "string",
		  group: "advanced", ui_label: "Masquerade" },
		{ name: "brutal_debug",             type: "bool",
		  group: "advanced", ui_label: "Brutal debug" },
		{ name: "ignore_client_bandwidth",  type: "bool",
		  group: "advanced", ui_label: "Ignore client bandwidth" },
		// NOTE: tls_* fields surfaced via shared UI; emitted by emit() via
		// inb.build_tls(). No transport / multiplex on hysteria2 inbound.
		// Merged into schema_dump() in D2.
	],
	emit: function(s) {
		let inb = require("inbound");
		let port = helpers.s_num(s.listen_port);
		if (!port) {
			warn(sprintf("inbound.uc: missing listen_port for '%s'; skipping\n", s[".name"]));
			return null;
		}
		let out = {
			type: "hysteria2",
			tag: s[".name"],
			listen: length(helpers.s_opt(s, "listen")) ? s.listen : "::",
			listen_port: port,
			users: [ inb.build_user(s) ],
		};
		let ot = helpers.s_opt(s, "hysteria2_obfs_type") || "none";
		if (ot !== "none" && length(helpers.s_opt(s, "hysteria2_obfs_password")))
			out.obfs = { type: ot, password: s.hysteria2_obfs_password };
		if (length(helpers.s_opt(s, "up_mbps")))   out.up_mbps   = helpers.s_num(s.up_mbps);
		if (length(helpers.s_opt(s, "down_mbps"))) out.down_mbps = helpers.s_num(s.down_mbps);
		if (length(helpers.s_opt(s, "hysteria2_masquerade")))
			out.masquerade = s.hysteria2_masquerade;
		if (helpers.s_bool(s, "brutal_debug")) out.brutal_debug = true;
		if (helpers.s_bool(s, "ignore_client_bandwidth"))
			out.ignore_client_bandwidth = true;
		let tls = inb.build_tls(s);
		if (tls) out.tls = tls;
		return out;
	},
});

return {};
