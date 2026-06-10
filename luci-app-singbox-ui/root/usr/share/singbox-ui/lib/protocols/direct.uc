// lib/protocols/direct.uc — Direct inbound (DNS / port-forward) and
// outbound (interface bind via dial fields). Replaces the old
// type=interface outbound.

let reg = require("protocols.registry");
let helpers = require("helpers");
let dial_blk = require("protocols._shared.dial");

const s_opt = helpers.s_opt;
const s_num = helpers.s_num;
const s_bool = helpers.s_bool;

reg.register({
	kind: "outbound", type: "direct", sing_box_type: "direct",
	shared: { dial: true },

	fields: [
		{ name: "override_address", type: "string", tab: "basic",
		  ui_label: "Override destination address",
		  placeholder: "127.0.0.1", advanced: true },
		{ name: "override_port", type: "number", tab: "basic",
		  ui_label: "Override destination port", advanced: true },
		{ name: "proxy_protocol", type: "enum", tab: "basic",
		  ui_label: "Proxy protocol version",
		  values: ["", "1", "2"], advanced: true },
	],

	emit: function(s) {
		let out = { type: "direct", tag: s[".name"] };
		if (length(s_opt(s, "override_address"))) out.override_address = s.override_address;
		if (length(s_opt(s, "override_port")))    out.override_port    = s_num(s.override_port);
		if (length(s_opt(s, "proxy_protocol")))   out.proxy_protocol   = s_num(s.proxy_protocol);
		let d = dial_blk.emit_outbound(s);
		for (let k in keys(d)) out[k] = d[k];
		return out;
	},
});

reg.register({
	kind: "inbound", type: "direct", sing_box_type: "direct",

	fields: [
		{ name: "listen", type: "string", tab: "basic", default: "::",
		  ui_label: "Listen address" },
		{ name: "listen_port", type: "number", tab: "basic", required: true,
		  validate: "port", ui_label: "Listen port" },
		{ name: "network", type: "enum", tab: "basic",
		  values: ["", "tcp", "udp"], ui_label: "Network" },
		{ name: "dns_listener", type: "bool", tab: "basic",
		  ui_label: "DNS listener (Hijack DNS via route rule)", default: 0 },
		{ name: "override_address", type: "string", tab: "basic",
		  ui_label: "Override destination address",
		  placeholder: "1.1.1.1", advanced: true },
		{ name: "override_port", type: "number", tab: "basic",
		  ui_label: "Override destination port", advanced: true },
		{ name: "tcp_fast_open", type: "bool", tab: "basic",
		  ui_label: "TCP fast open", default: 0, advanced: true },
		{ name: "udp_fragment", type: "bool", tab: "basic",
		  ui_label: "UDP fragment", default: 0, advanced: true },
	],

	emit: function(s) {
		let port = s_num(s.listen_port);
		if (!port) {
			warn(sprintf("direct inbound: missing listen_port for '%s'\n", s[".name"]));
			return null;
		}
		let out = {
			type: "direct",
			tag: s[".name"],
			listen: length(s_opt(s, "listen")) ? s.listen : "::",
			listen_port: port,
		};
		if (length(s_opt(s, "network"))) out.network = s.network;
		if (length(s_opt(s, "override_address"))) out.override_address = s.override_address;
		if (length(s_opt(s, "override_port")))    out.override_port    = s_num(s.override_port);
		if (s_bool(s, "tcp_fast_open")) out.tcp_fast_open = true;
		if (s_bool(s, "udp_fragment"))  out.udp_fragment  = true;
		return out;
	},
});

return {};
