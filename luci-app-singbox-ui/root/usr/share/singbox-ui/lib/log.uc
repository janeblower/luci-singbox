// lib/log.uc — sing-box `log` block.
// Reads `singbox-ui.log` section:
//   enabled '0'   → { disabled: true }
//   enabled '1'   → { level, output?, timestamp: true }
// Section absent → null (sing-box default: info).

function build_log(cur) {
	let s = cur.get_all("singbox-ui", "log");
	if (s == null) return null;
	if (s.enabled === "0") return { disabled: true };
	let out = { level: s.level || "info", timestamp: true };
	if (s.output != null && length(s.output)) out.output = s.output;
	return out;
}

return { build_log };
