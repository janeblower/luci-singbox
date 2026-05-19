// lib/inbound.uc — sing-box `inbounds` array: tproxy + per-outbound exposed inbounds.

let helpers = require("helpers");

function build_inbounds(cur) {
	let inbounds = [];

	if (helpers.get_bool(cur, "tproxy", "enabled")) {
		let port = +(cur.get("singbox-ui", "tproxy", "port") ?? "7893") || 7893;
		push(inbounds, {
			type: "tproxy",
			tag:  "tproxy_in",
			listen: "::",
			listen_port: port,
		});
	}

	cur.foreach("singbox-ui", "outbound", function(s) {
		if (s.enabled === "0") return;
		if (s.expose_proxy !== "1") return;
		let port = +s.expose_port;
		if (!port) return;

		let listen_ip = "0.0.0.0";
		let listen_iface = s.expose_listen;
		if (listen_iface != null && length(listen_iface)) {
			listen_ip = helpers.resolve_iface_ip(listen_iface);
			if (listen_ip == null) {
				warn(sprintf("inbound.uc: cannot resolve IPv4 for iface '%s'; skipping expose for outbound '%s'\n",
				             listen_iface, s[".name"]));
				return;
			}
		}

		let type = s.expose_type ?? "socks";
		// sing-box inbound types: "socks" (not "socks5"), "http", "mixed".

		push(inbounds, {
			type: type,
			tag:  "in_" + s[".name"],
			listen: listen_ip,
			listen_port: port,
		});
	});

	return inbounds;
}

return { build_inbounds };
