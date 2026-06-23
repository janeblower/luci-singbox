// lib/protocols/mixed.uc — Mixed inbound (HTTP + SOCKS5) under the E2 DSL.

let reg = require("builder.protocols.registry");

reg.register({
	kind: "inbound", type: "mixed", sing_box_type: "mixed",

	fields: [
		{ name: "listen", type: "string", tab: "basic", default: "::",
		  ui_label: "Listen address" },
		{ name: "listen_port", type: "number", tab: "basic", required: true,
		  validate: "port", default: 1080, ui_label: "Listen port" },
		{ name: "mixed_user", type: "list", tab: "basic", secret: true,
		  ui_label: "Users (username:password)",
		  placeholder: "alice:secret" },
	],

	users: {
		from: "mixed_user",
		columns: [
			{ key: "username", required: true },
			{ key: "password", always: true },
		],
	},
});

return {};
