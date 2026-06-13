// lib/protocols/direct.uc — Direct inbound (DNS / port-forward) and
// outbound (interface bind via dial fields). Replaces the old
// type=interface outbound.

let reg = require("builder.protocols.registry");

reg.register({
	kind: "outbound", type: "direct", sing_box_type: "direct",
	shared: { dial: true },

	fields: [
		{ name: "override_address", type: "string", tab: "basic",
		  ui_label: "Override destination address",
		  placeholder: "127.0.0.1", advanced: true,
		  json_key: "override_address" },
		{ name: "override_port", type: "number", tab: "basic",
		  ui_label: "Override destination port", advanced: true,
		  json_key: "override_port", coerce: "num" },
		{ name: "proxy_protocol", type: "enum", tab: "basic",
		  ui_label: "Proxy protocol version",
		  values: ["", "1", "2"], advanced: true,
		  json_key: "proxy_protocol", coerce: "num" },
	],
	// No emit(): filler builds {type,tag} + the three omit-if-empty fields + the
	// declared dial shared block, byte-identical to the former emit().
});

reg.register({
	kind: "inbound", type: "direct", sing_box_type: "direct",

	fields: [
		{ name: "listen", type: "string", tab: "basic", default: "::",
		  ui_label: "Listen address" },
		{ name: "listen_port", type: "number", tab: "basic", required: true,
		  validate: "port", ui_label: "Listen port" },
		{ name: "network", type: "enum", tab: "basic",
		  values: ["", "tcp", "udp"], ui_label: "Network", json_key: "network" },
		{ name: "dns_listener", type: "bool", tab: "basic",
		  ui_label: "DNS listener (Hijack DNS via route rule)", default: 0 },
		{ name: "override_address", type: "string", tab: "basic",
		  ui_label: "Override destination address",
		  placeholder: "1.1.1.1", advanced: true, json_key: "override_address" },
		{ name: "override_port", type: "number", tab: "basic",
		  ui_label: "Override destination port", advanced: true,
		  json_key: "override_port", coerce: "num" },
		{ name: "tcp_fast_open", type: "bool", tab: "basic",
		  ui_label: "TCP fast open", default: 0, advanced: true,
		  json_key: "tcp_fast_open", coerce: "bool" },
		{ name: "udp_fragment", type: "bool", tab: "basic",
		  ui_label: "UDP fragment", default: 0, advanced: true,
		  json_key: "udp_fragment", coerce: "bool" },
	],
});

return {};
