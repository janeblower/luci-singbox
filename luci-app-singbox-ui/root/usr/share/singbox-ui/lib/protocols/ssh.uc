// lib/protocols/ssh.uc — first reference descriptor. SSH outbound (sing-box
// 1.12+). New protocol, so no migration risk from legacy code paths.

let reg = require("protocols.registry");

reg.register({
	kind: "outbound",
	type: "ssh",
	sing_box_type: "ssh",
	fields: [
		{ name: "server",            type: "string", required: true,  validate: "host", group: "basic" },
		{ name: "server_port",       type: "number", default: 22,     validate: "port", group: "basic" },
		{ name: "user",              type: "string", required: true,                    group: "credentials" },
		{ name: "password",          type: "string", secret: true,                      group: "credentials" },
		{ name: "private_key_path",  type: "string",                                    group: "credentials" },
		{ name: "host_key",          type: "list",   item: "string",                    group: "advanced" },
	],
	emit: function(s) {
		let o = {
			type: "ssh",
			tag: s[".name"],
			server: s.server,
			server_port: +s.server_port || 22,
			user: s.user,
		};
		if (s.password)          o.password          = s.password;
		if (s.private_key_path)  o.private_key_path  = s.private_key_path;
		if (type(s.host_key) === "array" && length(s.host_key) > 0)
			o.host_key = s.host_key;
		return o;
	},
});

return {};
