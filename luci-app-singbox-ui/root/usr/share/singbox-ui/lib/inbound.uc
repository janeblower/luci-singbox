// lib/inbound.uc — sing-box `inbounds` array. tproxy (always) + per-outbound expose (Phase 2).

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

	return inbounds;
}

return { build_inbounds };
