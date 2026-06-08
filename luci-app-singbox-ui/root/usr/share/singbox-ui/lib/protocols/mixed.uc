// lib/protocols/mixed.uc — Mixed inbound (HTTP + SOCKS5) under the E2 DSL.

let reg = require("protocols.registry");
let helpers = require("helpers");

const s_opt    = helpers.s_opt;
const s_num    = helpers.s_num;
const as_array = helpers.as_array;

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

	emit: function(s) {
		let port = s_num(s.listen_port);
		if (!port) {
			warn(sprintf("mixed inbound: missing listen_port for '%s'\n", s[".name"]));
			return null;
		}
		let out = {
			type: "mixed",
			tag: s[".name"],
			listen: length(s_opt(s, "listen")) ? s.listen : "::",
			listen_port: port,
		};
		let users = [];
		for (let u in as_array(s.mixed_user)) {
			let parts = split(u, ":");
			if (length(parts) >= 2)
				push(users, { username: parts[0], password: parts[1] });
		}
		if (length(users)) out.users = users;
		return out;
	},
});

return {};
