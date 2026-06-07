// lib/protocols/tuic.uc — tuic outbound descriptor.
//
// Outbound emit is byte-equal to the legacy if-branches in
// lib/outbound.uc (build_constructor_for).

let reg = require("protocols.registry");
let helpers = require("helpers");

reg.register({
	kind: "outbound", type: "tuic", sing_box_type: "tuic",
	fields: [
		{ name: "server",               type: "string", required: true,
		  validate: "host", group: "basic" },
		{ name: "server_port",          type: "number", required: true,
		  validate: "port", group: "basic" },
		{ name: "server_uuid",          type: "string", required: true,
		  secret: true, validate: "uuid", group: "credentials", ui_label: "UUID" },
		{ name: "server_password",      type: "string", required: true,
		  secret: true, group: "credentials", ui_label: "Password" },
		{ name: "tuic_congestion",      type: "enum",
		  values: ["", "bbr", "cubic", "new_reno"],
		  group: "advanced", ui_label: "Congestion control" },
		{ name: "tuic_udp_relay_mode",  type: "enum",
		  values: ["", "native", "quic"],
		  group: "advanced", ui_label: "UDP relay mode" },
		{ name: "tuic_udp_over_stream", type: "bool",
		  group: "advanced", ui_label: "UDP over stream" },
		{ name: "tuic_zero_rtt",        type: "bool",
		  group: "advanced", ui_label: "Zero RTT handshake" },
		{ name: "tuic_heartbeat",       type: "string",
		  group: "advanced", ui_label: "Heartbeat" },
		{ name: "network",              type: "enum",
		  values: ["", "tcp", "udp"],
		  group: "advanced", ui_label: "Network" },
		// NOTE: tls_* fields are intentionally absent here. They are emitted
		// by emit() via the shared build_tls_client() helper in lib/outbound.uc,
		// and will be merged into schema_dump() output in D2.
		// Until then, reg.get("outbound","tuic").fields under-reports.
	],
	emit: function(s) {
		let ob = require("outbound");
		let out = {
			type:        "tuic",
			tag:         s[".name"],
			server:      helpers.s_opt(s, "server"),
			server_port: helpers.s_num(s.server_port),
		};
		if (length(helpers.s_opt(s, "server_uuid")))     out.uuid     = s.server_uuid;
		if (length(helpers.s_opt(s, "server_password"))) out.password = s.server_password;
		if (length(helpers.s_opt(s, "tuic_congestion")))
			out.congestion_control = s.tuic_congestion;
		let over_stream = helpers.s_bool(s, "tuic_udp_over_stream");
		if (over_stream) out.udp_over_stream = true;
		// udp_relay_mode mutually exclusive with udp_over_stream
		if (!over_stream && length(helpers.s_opt(s, "tuic_udp_relay_mode")))
			out.udp_relay_mode = s.tuic_udp_relay_mode;
		if (helpers.s_bool(s, "tuic_zero_rtt")) out.zero_rtt_handshake = true;
		if (length(helpers.s_opt(s, "tuic_heartbeat"))) out.heartbeat = s.tuic_heartbeat;
		if (length(helpers.s_opt(s, "network")) && (s.network === "tcp" || s.network === "udp"))
			out.network = s.network;
		let tls = ob.build_tls_client(s, "tuic");
		if (tls) out.tls = tls;
		return out;
	},
});
