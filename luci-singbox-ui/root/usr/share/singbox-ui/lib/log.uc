// lib/log.uc — sing-box `log` block + structured event logger for our
// own ops logging.

// --- sing-box log block (unchanged) ---
function build_log(cur) {
	let s = cur.get_all("singbox-ui", "log");
	if (s == null) return null;
	if (s.enabled === "0") return { disabled: true };
	let out = { level: s.level || "info", timestamp: true };
	if (s.output != null && length(s.output)) out.output = s.output;
	return out;
}

// --- Structured event logger ---
// Default sink uses `logger -t singbox-ui -p <level>` (busybox).
let _logger = function(level, line) {
	let fs_mod = require("fs");
	let p = fs_mod.popen(["logger", "-t", "singbox-ui", "-p", level], "w");
	if (p) { p.write(line + "\n"); p.close(); }
};

// _set_logger_for_test(fn) — override sink for tests. fn(level, line) -> void.
function _set_logger_for_test(fn) { _logger = fn; }

// log_event(level, event, kv) — emit a structured line:
//   event=<name> ts=<unix> key=val key=val ...
// Values containing whitespace or " are wrapped in JSON quoting via %J.
function log_event(level, event, kv) {
	let parts = [];
	push(parts, sprintf("event=%s", event));
	push(parts, sprintf("ts=%d", time()));
	if (type(kv) === "object") {
		for (let k, v in kv) {
			let s;
			if (v == null)                          s = "";
			else if (type(v) === "string")          s = match(v, /[ \t\n\r"]/) ? sprintf("%J", v) : v;
			else if (type(v) === "bool")            s = v ? "true" : "false";
			else                                    s = sprintf("%s", v);
			push(parts, sprintf("%s=%s", k, s));
		}
	}
	_logger(level, join(" ", parts));
}

return { build_log, log_event, _set_logger_for_test };
