// lib/protocols/anytls.uc — anytls outbound descriptor.
//
// Outbound emit is byte-equal to the legacy if-branches in
// lib/outbound.uc (build_constructor_for).

let reg = require("protocols.registry");
let helpers = require("helpers");

reg.register({
	kind: "outbound", type: "anytls", sing_box_type: "anytls",
	fields: [
		{ name: "server",                       type: "string", required: true,
		  validate: "host", group: "basic" },
		{ name: "server_port",                  type: "number", required: true,
		  validate: "port", group: "basic" },
		{ name: "server_password",              type: "string", required: true,
		  secret: true, group: "credentials", ui_label: "Password" },
		{ name: "anytls_idle_check_interval",   type: "string",
		  group: "advanced", ui_label: "Idle check interval" },
		{ name: "anytls_idle_timeout",          type: "string",
		  group: "advanced", ui_label: "Idle timeout" },
		{ name: "anytls_min_idle_session",      type: "number",
		  group: "advanced", ui_label: "Min idle session" },
		// NOTE: tls_* fields are intentionally absent here. They are emitted
		// by emit() via the shared build_tls_client() helper in lib/outbound.uc,
		// and will be merged into schema_dump() output in D2.
		// Until then, reg.get("outbound","anytls").fields under-reports.
	],
	emit: function(s) {
		let ob = require("outbound");
		let out = {
			type:        "anytls",
			tag:         s[".name"],
			server:      helpers.s_opt(s, "server"),
			server_port: helpers.s_num(s.server_port),
		};
		if (length(helpers.s_opt(s, "server_password"))) out.password = s.server_password;
		if (length(helpers.s_opt(s, "anytls_idle_check_interval")))
			out.idle_session_check_interval = s.anytls_idle_check_interval;
		if (length(helpers.s_opt(s, "anytls_idle_timeout")))
			out.idle_session_timeout = s.anytls_idle_timeout;
		let m = helpers.s_num(s.anytls_min_idle_session);
		if (m > 0) out.min_idle_session = m;
		let tls = ob.build_tls_client(s, "anytls");
		if (tls) out.tls = tls;
		return out;
	},
});

return {};
