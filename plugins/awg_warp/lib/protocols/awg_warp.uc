// lib/plugins/awg_warp/protocols/awg_warp.uc — AWG-WARP outbound = a `direct` outbound
// bound to the plugin's amneziawg interface. WARP creds + AWG params are UCI-only
// (drive the reconciler); only bind_interface reaches sing-box JSON.
let reg = require("builder.protocols.registry");
let ifaceh = require("plugins.awg_warp.iface");

reg.try_register({
	kind: "outbound", type: "awg_warp", sing_box_type: "direct",

	// Backend-only + UI fields. json_key-less fields never reach sing-box JSON.
	fields: [
		{ name: "warp_storage", type: "enum", tab: "basic", ui_label: "Config storage (RAM/Flash)",
		  values: ["ram","flash"], default: "ram" },
		{ name: "awg_mimic", type: "enum", tab: "basic", ui_label: "Mimic protocol",
		  values: ["auto","quic","dns","stun","dtls","sip","tls","static"] },
		{ name: "ipv6_enabled", type: "bool", tab: "basic", ui_label: "Enable IPv6 (auto-masquerade)", default: 0 },
		{ name: "mtu_override", type: "number", tab: "basic", ui_label: "MTU (empty = WAN-80)", advanced: true },
		// warp_* creds + awg_jc/jmin/jmax are written by rpcd (register/generate),
		// surfaced read-only in the form; not declared as writable JSON fields.
	],

	// escape-hatch emit: produce {type:direct, tag, bind_interface}. No listen base.
	emit: function(s) {
		return {
			type: "direct",
			tag: s[".name"],
			bind_interface: ifaceh.iface_name(s[".name"]),
		};
	},
});

return {};
