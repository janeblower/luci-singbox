// lib/plugins/awg_warp/nft.uc — masquerade fragment for AWG-WARP egress.
// Sanitizes every interface name twice: via iface.iface_name() (length/truncation)
// and through _safe_iface() ([a-z0-9_]-only filter) before embedding in nft text.
//
// Emits:
//   table ip singbox_ui_awg_nat    — ip4-only postrouting masquerade for each enabled iface
//   table ip6 singbox_ui_awg_nat6  — NAT66 postrouting masquerade (ipv6_enabled + v6 addr present in .conf)
let ifaceh    = require("plugins.awg_warp.iface");
let confstore = require("plugins.awg_warp.confstore");
let fs        = require("fs");

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
		// v6addr sourced from stored .conf (NOT from UCI warp_address_v6 — field removed).
		let v6addr = "";
		let storage = (s.warp_storage == "flash") ? "flash" : "ram";
		let raw = fs.readfile(confstore.conf_path(s[".name"], storage));
		if (raw != null && length(raw)) {
			let wg = confstore.parse_full(raw);
			if (wg != null) v6addr = wg.address_v6 ?? "";
		}
		if (s.ipv6_enabled == "1" && length(v6addr))
			push(v6_rules, sprintf("\t\toifname \"%s\" masquerade", dev));
	});
	// Reset both tables on EVERY apply, exactly like the core table does
	// (`add table` creates it if missing so `delete table` cannot fail, then the
	// definition below re-creates it). Without this the fragment only ever
	// APPENDED, so each apply added another `oifname ... masquerade` rule and the
	// ruleset grew without bound — and a table whose outbounds were all removed or
	// disabled was never torn down at all.
	let out = "";
	out += "add table ip singbox_ui_awg_nat\n";
	out += "delete table ip singbox_ui_awg_nat\n";
	out += "add table ip6 singbox_ui_awg_nat6\n";
	out += "delete table ip6 singbox_ui_awg_nat6\n";

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

// remove_tables — drop both NAT tables outright. The fragment above can only tear
// them down while the plugin is still enabled; once it is switched off (or the
// package removed) the registry stops handing out its nft hook, so the lifecycle
// teardown has to do it.
function remove_tables() {
	system(["nft", "delete", "table", "ip", "singbox_ui_awg_nat"]);
	system(["nft", "delete", "table", "ip6", "singbox_ui_awg_nat6"]);
}

return { fragment, remove_tables };
