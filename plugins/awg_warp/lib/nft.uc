// lib/plugins/awg_warp/nft.uc — masquerade fragment for AWG-WARP egress.
// Sanitizes every interface name twice: via iface.iface_name() (length/truncation)
// and through _safe_iface() ([a-z0-9_]-only filter) before embedding in nft text.
//
// Emits:
//   table ip singbox_ui_awg_nat    — ip4-only postrouting masquerade for each enabled iface
//   table ip6 singbox_ui_awg_nat6  — NAT66 postrouting masquerade (ipv6_enabled + v6 addr)
let ifaceh = require("plugins.awg_warp.iface");

// _safe_iface: additional [a-z0-9_]-only filter (HIGH-severity injection guard).
// iface_name already lowercases and filters, but an env-override seam could bypass
// it, so we double-filter here before any string lands in the nft fragment.
function _safe_iface(name) {
	let s = ""; let n = "" + (name != null ? name : "");
	for (let i = 0; i < length(n); i++) {
		let c = substr(n, i, 1);
		if (match(c, /[a-z0-9_]/)) s += c;
	}
	return s;
}

function fragment(cur) {
	let v4_rules = [], v6_rules = [];
	cur.foreach("singbox-ui", "outbound", function(s) {
		if (s.type != "awg_warp" || s.enabled == "0") return;
		let dev = _safe_iface(ifaceh.iface_name(s[".name"]));
		if (!length(dev)) return;
		push(v4_rules, sprintf("\t\toifname \"%s\" masquerade", dev));
		let v6addr = "" + (s.warp_address_v6 != null ? s.warp_address_v6 : "");
		if (s.ipv6_enabled == "1" && length(v6addr))
			push(v6_rules, sprintf("\t\toifname \"%s\" masquerade", dev));
	});
	if (!length(v4_rules) && !length(v6_rules)) return "";
	let out = "";
	if (length(v4_rules)) {
		out += "table ip singbox_ui_awg_nat {\n";
		out += "\tchain postrouting {\n\t\ttype nat hook postrouting priority srcnat; policy accept;\n";
		for (let r in v4_rules) out += r + "\n";
		out += "\t}\n}\n";
	}
	if (length(v6_rules)) {
		out += "table ip6 singbox_ui_awg_nat6 {\n";
		out += "\tchain postrouting {\n\t\ttype nat hook postrouting priority srcnat; policy accept;\n";
		for (let r in v6_rules) out += r + "\n";
		out += "\t}\n}\n";
	}
	return out;
}

return { fragment };
