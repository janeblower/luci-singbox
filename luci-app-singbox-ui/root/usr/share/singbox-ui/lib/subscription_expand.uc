// lib/subscription_expand.uc — expand a subscription state file into a
// concrete list of outbound objects. Reads /tmp/singbox-ui/sub_<name>.txt
// (one share-link URL per line) and parses each via outbound.uc helpers.
//
// Environment overrides:
//   SUB_TMPDIR           — override TMPDIR for tests (default /tmp/singbox-ui)
//   SINGBOX_UI_SUB_DIR   — alias of SUB_TMPDIR; either takes effect.

let ob = require("outbound");
let fs = require("fs");

const TMPDIR = getenv("SUB_TMPDIR") ||
			   getenv("SINGBOX_UI_SUB_DIR") ||
			   "/tmp/singbox-ui";

function read_urls(name) {
	let path = sprintf("%s/sub_%s.txt", TMPDIR, name);
	let raw;
	try { raw = fs.readfile(path); }
	catch (e) { return []; }
	if (!length(raw)) return [];
	let out = [];
	for (let line in split(raw, "\n")) {
		let s = trim(line);
		if (length(s)) push(out, s);
	}
	return out;
}

function expand(name) {
	let urls = read_urls(name);
	let out = [];
	for (let u in urls) {
		let parsed = ob.parse_proxy_url(u);
		if (!parsed) continue;
		let tag = parsed.tag || sprintf("%s_%d", name, length(out) + 1);
		push(out, {
			tag: tag,
			type: parsed.type,
			server: parsed.server,
			server_port: parsed.server_port,
			fields: parsed,
		});
	}
	return out;
}

return { expand };
